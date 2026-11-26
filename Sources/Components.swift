// Native blur background for the translation popup.

import AppKit
import SwiftUI

/// Popover-style blur with real rounded corners (the translation popup).
struct VisualEffect: NSViewRepresentable {
    var cornerRadius: CGFloat = 16

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = roundedMask(radius: cornerRadius)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    /// A stretchable rounded rect — NSVisualEffectView ignores SwiftUI clip shapes.
    private func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

extension NSMenuItem {
    /// macOS 27 hides menu item images unless asked; the menu's icons are part of its design.
    func showsImage() {
        if #available(macOS 27.0, *) { preferredImageVisibility = .visible }
    }
}
