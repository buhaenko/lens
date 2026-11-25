// Full-screen overlay for dragging the area to scan: dims the screen, Esc or right-click cancels.

import AppKit
import Carbon.HIToolbox

final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class SelectionView: NSView {
    /// Called with the selected rect in screen coordinates, or nil when cancelled.
    var onDone: (NSRect?) -> Void = { _ in }
    private var start: NSPoint?
    private var selection: NSRect = .zero

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

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
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                           width: abs(point.x - start.x), height: abs(point.y - start.y)).integral
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
