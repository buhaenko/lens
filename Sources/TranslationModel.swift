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

    var scanID = UUID()

    /// Show a past scan without re-translating (Tab still works).
    func restore(_ scan: Scan) {
        scanID = scan.id
        original = scan.original
        translated = scan.translated
        source = scan.source
        target = scan.target
        copied = false
        busy = false
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

    /// Kicks off a translation: PopupView's `.translationTask(config)` runs it and writes `translated`.
    func translate() {
        guard !original.isEmpty else { return }
        let from = source.map { Locale.Language(identifier: $0) }
        let to = Locale.Language(identifier: target)
        if from?.languageCode == to.languageCode {         // already in the target language
            translated = original
            busy = false
            record()
            return
        }
        busy = true
        if var same = config, same.source == from, same.target == to {
            same.invalidate()                               // same pair again → force a re-run
            config = same
        } else {
            config = .init(source: from, target: to)
        }
    }

    func copy(original copyOriginal: Bool = false) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(copyOriginal ? original : translated, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
    }
}
