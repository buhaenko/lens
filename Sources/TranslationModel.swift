// State of the translation popup: text, languages, cycling, copying.

import AppKit
import SwiftUI
import Translation

@MainActor final class TranslationModel: ObservableObject {
    @Published var original = ""
    @Published var translated = ""
    @Published var source: String?
    @Published var target = defaults.string(forKey: "target") ?? langs.first?.id ?? "en"
    @Published var busy = false
    @Published var copied = false
    @Published var config: TranslationSession.Configuration?
    /// Why there's no translation — shown in the popup instead of an endless loading bar.
    @Published var problem: Problem?

    enum Problem: Equatable {
        case notDownloaded([String])    // these languages have to be downloaded first
        case unsupported                // Apple can't translate this pair
        case failed(String)
    }

    var scanID = UUID()
    /// "Download" in the popup: the app opens the languages window and retries afterwards.
    var onDownload: ([String]) -> Void = { _ in }
    /// Swappable in tests.
    var checkPair: (String?, String, String) async -> LanguageAvailability.Status = LanguageDownloads.pairStatus
    var findMissing: (String?, String) async -> [String] = LanguageDownloads.missing
    var timeout: Duration = .seconds(25)
    private var attempt = UUID()

    /// Show a past scan without re-translating (Tab still works).
    func restore(_ scan: Scan) {
        scanID = scan.id
        original = scan.original
        translated = scan.translated
        source = scan.source
        target = scan.target
        copied = false
        busy = false
        problem = nil
        attempt = UUID()
    }

    func record() {
        guard !original.isEmpty, !translated.isEmpty else { return }
        if defaults.object(forKey: "autoCopy") as? Bool ?? false { copy() }
        guard defaults.object(forKey: "saveHistory") as? Bool ?? true,
              HistoryFilter.current.reasonToSkip(original, source: source) == nil else { return }
        History.shared.upsert(Scan(id: scanID, original: original, translated: translated, source: source, target: target))
    }

    func load(_ text: String) {
        scanID = UUID()
        original = text; translated = ""; copied = false
        source = detectLanguage(text)
        if !langs.contains(where: { $0.id == target }) { target = langs.first?.id ?? "en" }
        if source == target { target = langs.first { $0.id != source }?.id ?? target }
        translate()
    }

    /// Tab / ⇧Tab: next or previous language, skipping the source language.
    func cycle(_ step: Int) {
        let list = langs
        guard let current = list.firstIndex(where: { $0.id == target }) else { return }
        for offset in 1...list.count {
            let next = list[((current + step * offset) % list.count + list.count) % list.count]
            if next.id != source { select(next.id); return }
        }
    }

    func select(_ id: String) {
        target = id
        defaults.set(id, forKey: "target")
        copied = false
        translate()
    }

    /// Kicks off a translation: first checks the languages are on this Mac, then PopupView's
    /// `.translationTask(config)` runs it and calls `finish` / `fail`.
    func translate() {
        guard !original.isEmpty else { return }
        problem = nil
        let from = source.map { Locale.Language(identifier: $0) }
        let to = Locale.Language(identifier: target)
        let id = UUID(); attempt = id
        if from?.languageCode == to.languageCode {         // already in the target language
            translated = original
            busy = false
            record()
            return
        }
        busy = true
        let (src, tgt, text) = (source, target, original)
        let (check, findMissing, timeout) = (checkPair, findMissing, timeout)
        Task {
            let status = await check(src, tgt, text)
            guard attempt == id else { return }            // another scan or language came in meanwhile
            switch status {
            case .installed:
                if var same = config, same.source == from, same.target == to {
                    same.invalidate()                       // same pair again → force a re-run
                    config = same
                } else {
                    config = .init(source: from, target: to)
                }
                try? await Task.sleep(for: timeout)
                if attempt == id && busy { fail(String(localized: "It’s taking too long — macOS didn’t answer.")) }
            case .unsupported:
                busy = false; problem = .unsupported
            default:
                let missing = await findMissing(src, tgt)
                guard attempt == id else { return }
                busy = false; problem = .notDownloaded(missing)
            }
        }
    }

    func finish(_ text: String) {
        translated = text
        problem = nil
        busy = false
        record()
    }

    func fail(_ reason: String) {
        translated = ""
        busy = false
        problem = .failed(reason)
    }

    /// ↩ in the popup: the obvious next step for the problem shown.
    func fix() {
        switch problem {
        case .notDownloaded(let ids): onDownload(ids)
        case .failed: translate()
        default: break
        }
    }

    func copy(original copyOriginal: Bool = false) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(copyOriginal || translated.isEmpty ? original : translated, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
    }
}
