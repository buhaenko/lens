// Menu bar icon — the user picks one of three in Settings. Template images follow the menu bar's colour.

import AppKit

enum MenuBarIcon: String, CaseIterable, Identifiable {
    case translate, scanText, prism
    var id: String { rawValue }

    static let changed = Notification.Name("LensMenuBarIconChanged")
    static var current: MenuBarIcon { MenuBarIcon(rawValue: defaults.string(forKey: "menuBarIcon") ?? "") ?? .translate }

    var title: String {
        switch self {
        case .translate: String(localized: "Translate")
        case .scanText: String(localized: "Scan text")
        case .prism: String(localized: "Prism")
        }
    }

    var image: NSImage {
        let image: NSImage
        switch self {
        case .translate: image = symbol("translate")
        case .scanText: image = symbol("text.viewfinder")
        case .prism: image = prismGlyph()
        }
        image.isTemplate = true
        return image
    }

    private func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: "Lensy")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium)) ?? prismGlyph()
    }
}

/// A glass prism: one beam of light in, a fan out (one text, many languages).
private func prismGlyph() -> NSImage {
    NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        func line(_ from: NSPoint, _ to: NSPoint) {
            let path = NSBezierPath()
            path.move(to: from)
            path.line(to: to)
            path.lineWidth = 1.3
            path.lineCapStyle = .round
            path.stroke()
        }
        NSColor.black.setStroke()
        line(NSPoint(x: 0.6, y: 7.2), NSPoint(x: 5.6, y: 9.6))

        let prism = NSBezierPath()
        prism.move(to: NSPoint(x: 8.2, y: 15.2))
        prism.line(to: NSPoint(x: 3.6, y: 4.8))
        prism.line(to: NSPoint(x: 12.8, y: 4.8))
        prism.close()
        NSColor.black.withAlphaComponent(0.22).setFill()
        prism.fill()
        prism.lineWidth = 1.4
        prism.lineJoinStyle = .round
        prism.stroke()

        line(NSPoint(x: 10.7, y: 10.6), NSPoint(x: 17.3, y: 13.6))
        line(NSPoint(x: 11.2, y: 9.5), NSPoint(x: 17.3, y: 9.9))
        line(NSPoint(x: 11.7, y: 8.4), NSPoint(x: 17.3, y: 6.2))
        return true
    }
}
