// The translation popup window: placement next to the selection, sizing, keyboard.

import AppKit
import SwiftUI
import Carbon.HIToolbox

extension AppDelegate: NSWindowDelegate {
    func setUpPopupPanel() {
        let host = NSHostingView(rootView: PopupView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        panel = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu                     // above normal and floating windows
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.delegate = self
        sizeObserver = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.fitPopupToContent() }
        }
    }

    /// Below the selection, left-aligned; above it when there's no room; clamped to the screen.
    func showPopup(below anchor: NSRect) {
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 420, height: 200)
        let center = NSPoint(x: anchor.midX, y: anchor.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame, gap: CGFloat = 10, margin: CGFloat = 8

        var origin = NSPoint(x: anchor.minX, y: anchor.minY - gap - size.height)
        anchoredBelow = true
        if origin.y < visible.minY + margin {
            origin.y = anchor.maxY + gap
            anchoredBelow = false
            if origin.y + size.height > visible.maxY - margin {        // no room above either → bottom of the selection
                origin.y = max(visible.minY + margin, anchor.minY + gap)
                anchoredBelow = true
            }
        }
        origin.x = min(max(origin.x, visible.minX + margin), visible.maxX - size.width - margin)
        origin.y = min(max(origin.y, visible.minY + margin), visible.maxY - size.height - margin)

        // fades in while settling the last few points towards the selection
        let final = NSRect(origin: origin, size: size)
        popupFrame = final
        let lift: CGFloat = Motion.reduced ? 0 : (anchoredBelow ? -6 : 6)
        panel.setFrame(final.offsetBy(dx: 0, dy: lift), display: true)
        panel.alphaValue = 0
        shownAt = Date()
        panel.orderFrontRegardless()    // on top even though Lensy isn't the active app
        panel.makeKey()                 // non-activating: takes keys without stealing focus
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(final, display: true)
        }
        panel.invalidateShadow()
        installPopupKeys()
    }

    func hidePopup() {
        guard let panel, panel.isVisible else { return }
        removePopupKeys()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; $0.timingFunction = CAMediaTimingFunction(name: .easeIn); panel.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { if panel.alphaValue < 0.05 { panel.orderOut(nil) } }   // unless re-shown meanwhile
        }
    }

    /// Open a past scan from the history, centred under the menu bar icon.
    func reopen(_ scan: Scan) {
        popover.performClose(nil)
        model.restore(scan)
        var anchor = NSRect(origin: NSEvent.mouseLocation, size: .zero)
        if let button = statusItem.button, let window = button.window {
            let icon = window.convertToScreen(button.frame)
            anchor = NSRect(x: icon.midX - 210, y: icon.minY - 2, width: 420, height: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.showPopup(below: anchor) }
    }

    /// Grow/shrink with the content, keeping the edge that touches the selection in place.
    private func fitPopupToContent() {
        guard panel.isVisible, let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        guard abs(size.height - panel.frame.height) > 0.5,
              let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        // while it's still sliding in, grow from where it's going, not from where it is
        var frame = Date().timeIntervalSince(shownAt) < 0.3 ? popupFrame ?? panel.frame : panel.frame
        if anchoredBelow { frame.origin.y = max(frame.maxY - size.height, screen.visibleFrame.minY + 8) }
        else { frame.origin.y = min(frame.minY, screen.visibleFrame.maxY - 8 - size.height) }
        frame.size = size
        popupFrame = frame
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }
        panel.invalidateShadow()
    }

    func windowDidResignKey(_ notification: Notification) {
        if !capturing && Date().timeIntervalSince(shownAt) > 0.4 { hidePopup() }
    }

    // Tab / ⇧Tab language · ↩ download / try again · ⌘C copy translation · ⌥⌘C copy original · Esc close
    private func installPopupKeys() {
        removePopupKeys()
        popupKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = Int(event.keyCode)
            let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let handled: Bool = MainActor.assumeIsolated {
                guard let self else { return false }
                switch code {
                case kVK_Escape: self.hidePopup()
                case kVK_Tab: self.model.cycle(mods.contains(.shift) ? -1 : 1)
                case kVK_Return where self.model.problem != nil, kVK_ANSI_KeypadEnter where self.model.problem != nil: self.model.fix()
                case kVK_ANSI_C where mods.contains(.command): self.model.copy(original: mods.contains(.option))
                default: return false
                }
                return true
            }
            return handled ? nil : event
        }
    }

    private func removePopupKeys() {
        if let monitor = popupKeyMonitor { NSEvent.removeMonitor(monitor) }
        popupKeyMonitor = nil
    }
}

/// Borderless panel that can take keyboard focus without activating Lensy.
final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
