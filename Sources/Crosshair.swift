// The pointer while selecting an area: a small, fine cross.
// White with a thin dark edge, so it reads on bright pages and dark videos alike.

import AppKit

enum Crosshair {
    static let side: CGFloat = 24

    static let cursor = NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))

    /// Vector-drawn, so it stays crisp on any display. Hot spot in the middle.
    static var image: NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY)
            let gap: CGFloat = 2.5, arm: CGFloat = 7, dot: CGFloat = 0.85
            let path = NSBezierPath()
            for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] as [(CGFloat, CGFloat)] {
                path.move(to: NSPoint(x: c.x + dx * gap, y: c.y + dy * gap))
                path.line(to: NSPoint(x: c.x + dx * arm, y: c.y + dy * arm))
            }
            path.lineCapStyle = .round
            path.lineWidth = 1.25

            // a fine dark edge with a soft glow, then the white line on top
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = .zero
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            NSColor.black.withAlphaComponent(0.5).set()
            let edge = path.copy() as! NSBezierPath
            edge.lineWidth = path.lineWidth + 1.3
            edge.stroke()
            NSBezierPath(ovalIn: NSRect(x: c.x - dot - 0.65, y: c.y - dot - 0.65, width: dot * 2 + 1.3, height: dot * 2 + 1.3)).fill()
            NSGraphicsContext.restoreGraphicsState()

            NSColor.white.set()
            path.stroke()
            NSBezierPath(ovalIn: NSRect(x: c.x - dot, y: c.y - dot, width: dot * 2, height: dot * 2)).fill()
            return true
        }
    }
}
