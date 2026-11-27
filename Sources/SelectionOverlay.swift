// Full-screen overlay for dragging the area to scan: dims the screen, Esc or right-click cancels.
// Built to show up on top of everything — full-screen videos, games, other overlays — and to keep its
// small cross pointer even when another app hides or changes the cursor.

import AppKit
import Carbon.HIToolbox

final class OverlayWindow: NSPanel {
    /// The highest level a normal app can use: above full-screen apps, video players, menus and other overlays.
    static let topLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))

    let selection: SelectionView
    let display: NSScreen

    init(screen: NSScreen) {
        display = screen
        selection = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = Self.topLevel
        // every Space, including other apps' full-screen ones; ignored by Mission Control and ⌘`
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false          // panels vanish when the app loses focus by default
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        acceptsMouseMovedEvents = true
        contentView = selection
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
}

final class SelectionView: NSView {
    /// Called with the selected rect in screen coordinates, or nil when cancelled.
    var onDone: (NSRect?) -> Void = { _ in }
    private var start: NSPoint?
    private var selection: NSRect = .zero
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: Crosshair.cursor) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    private func track(_ event: NSEvent) { Crosshair.cursor.set() }

    override func cursorUpdate(with event: NSEvent) { Crosshair.cursor.set() }
    override func mouseMoved(with event: NSEvent) { track(event) }
    override func mouseEntered(with event: NSEvent) { track(event) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.22).setFill()
        bounds.fill()
        guard selection.width > 0, selection.height > 0 else { return }
        NSColor.clear.setFill()
        selection.fill(using: .copy)
        let border = NSBezierPath(roundedRect: selection.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        border.lineWidth = 1
        NSColor.white.withAlphaComponent(0.9).setStroke()
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        selection = .zero
        track(event)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                           width: abs(point.x - start.x), height: abs(point.y - start.y)).integral
        track(event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard selection.width > 4, selection.height > 4, let window else { onDone(nil); return }
        onDone(window.convertToScreen(convert(selection, to: nil)))
    }

    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape { onDone(nil) }
    }

    override func rightMouseDown(with event: NSEvent) { onDone(nil) }
}
