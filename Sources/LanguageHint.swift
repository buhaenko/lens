// The small pill at the top of the selection overlay: which language the scan translates into, and whether
// it's downloaded — so nobody drags a selection only to find out afterwards that nothing can be translated.

import AppKit
import SwiftUI

struct LanguageHint: Equatable {
    enum State: Equatable { case checking, ready, missing, unsupported }
    var target: String
    var state: State
    var othersMissing: [String] = []

    /// What the next scan will translate into (same rule as TranslationModel.load) and what the store knows about it.
    @MainActor static func current(target saved: String, packs given: LanguageDownloads? = nil, list: [Lang] = langs) -> LanguageHint {
        let packs = given ?? .shared
        let target = list.contains { $0.id == saved } ? saved : list.first?.id ?? "en"
        let state: State = switch packs.status[target] {
        case .ready: .ready
        case .needed, .failed: .missing
        case .unsupported: .unsupported
        case .checking, .downloading, nil: .checking
        }
        let others = list.map(\.id).filter { $0 != target && [.needed, .failed].contains(packs.status[$0]) }
        return LanguageHint(target: target, state: state, othersMissing: others)
    }

    /// Languages "D" downloads from the overlay.
    var toDownload: [String] { (state == .missing ? [target] : []) + othersMissing }

    var text: String {
        let name = makeLang(target).name
        switch state {
        case .missing: return String(localized: "\(name) isn’t downloaded yet — press D to download it")
        case .unsupported: return String(localized: "Apple can’t translate into \(name)")
        case .checking, .ready:
            guard !othersMissing.isEmpty else { return String(localized: "Translating to \(name)") }
            let names = ListFormatter.localizedString(byJoining: othersMissing.map { makeLang($0).name })
            return String(localized: "Translating to \(name) · \(names) not downloaded — press D")
        }
    }

    var symbol: String {
        switch state {
        case .ready: othersMissing.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        case .missing: "arrow.down.circle.fill"
        case .unsupported: "nosign"
        case .checking: "globe"
        }
    }
}

struct LanguageHintView: View {
    let hint: LanguageHint

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: hint.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
            Text(hint.text).font(.system(size: 12.5, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 13).padding(.vertical, 7)
        .background(Capsule().fill(Color.black.opacity(0.62)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14)))
        .fixedSize()
    }

    private var tint: Color {
        switch hint.state {
        case .ready: hint.othersMissing.isEmpty ? .green : .orange
        case .missing: .orange
        case .unsupported, .checking: .white.opacity(0.7)
        }
    }
}

/// Shows SwiftUI on the overlay without catching any clicks — the selection underneath gets them all.
final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension OverlayWindow {
    func show(_ hint: LanguageHint) {
        let view = (selection.subviews.first as? PassThroughHostingView<LanguageHintView>) ?? {
            let view = PassThroughHostingView(rootView: LanguageHintView(hint: hint))
            selection.addSubview(view)
            return view
        }()
        view.rootView = LanguageHintView(hint: hint)
        let size = view.fittingSize
        let menuBar = max(display.frame.maxY - display.visibleFrame.maxY, 24)
        view.frame = NSRect(x: (selection.bounds.width - size.width) / 2, y: selection.bounds.height - menuBar - 14 - size.height,
                            width: size.width, height: size.height).integral
    }
}
