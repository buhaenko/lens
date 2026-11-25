// Scan flow: selection overlay → screen capture → text recognition → popup.

import AppKit

extension AppDelegate {
    @objc func capture() {
        guard !capturing else { return }
        capturing = true
        hidePopup()
        popover.performClose(nil)

        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onDone = { [weak self] rect in self?.selectionFinished(rect) }
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            overlays.append(window)
        }
        // Esc goes to the overlay under the mouse
        let mouse = NSEvent.mouseLocation
        if let window = overlays.first(where: { $0.frame.contains(mouse) }) ?? overlays.first {
            window.makeKey()
            window.makeFirstResponder(window.contentView)
        }
        NSCursor.crosshair.set()
    }

    private func selectionFinished(_ rect: NSRect?) {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        NSCursor.arrow.set()
        guard let rect else { capturing = false; return }
        // let the overlay leave the screen first, then grab exactly that rect
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { self.scan(rect) }
    }

    private func scan(_ rect: NSRect) {
        Task { @MainActor in
            let image = await captureScreen(rect)
            capturing = false
            guard let image else {
                NSSound.beep()
                if !CGPreflightScreenCaptureAccess() { openSettings() }   // show what's missing
                return
            }
            let text = await recognize(image)
            guard !text.isEmpty else { NSSound.beep(); return }
            model.load(text)
            showPopup(below: rect)
        }
    }
}
