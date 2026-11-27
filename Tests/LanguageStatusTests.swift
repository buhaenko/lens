// A language that isn't downloaded must never mean "select text and see nothing":
// the overlay says so before the selection, the popup says so instead of loading forever, and Download fixes it.

import AppKit
import SwiftUI
import Translation

@MainActor func spin(_ done: () -> Bool, timeout: TimeInterval = 3) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    return done()
}

@MainActor func runLanguageStatusTests() {
    let savedLanguages = defaults.stringArray(forKey: "languages")
    let savedTarget = defaults.string(forKey: "target")
    defer {
        if let savedLanguages { defaults.set(savedLanguages, forKey: "languages") } else { defaults.removeObject(forKey: "languages") }
        if let savedTarget { defaults.set(savedTarget, forKey: "target") } else { defaults.removeObject(forKey: "target") }
    }
    defaults.set(["en", "uk", "fr"], forKey: "languages")

    section("Overlay hint — the language status before selecting")
    let packs = LanguageDownloads(selected: ["en", "uk", "fr"])
    packs.status = ["en": .ready, "uk": .ready, "fr": .ready]
    var hint = LanguageHint.current(target: "uk", packs: packs)
    expectEqual(hint.state, .ready, "a downloaded target is ready")
    expect(hint.text.hasPrefix("Translating to Українська"), "says where the scan goes: «\(hint.text)»")
    expect(hint.toDownload.isEmpty, "nothing to download")
    packs.status["uk"] = .needed
    hint = LanguageHint.current(target: "uk", packs: packs)
    expectEqual(hint.state, .missing, "a target that isn't downloaded is flagged")
    expect(hint.text.contains("isn’t downloaded") && hint.text.contains("press D"), "and says how to fix it: «\(hint.text)»")
    expectEqual(hint.toDownload, ["uk"], "D downloads it")
    packs.status = ["en": .ready, "uk": .ready, "fr": .failed]
    hint = LanguageHint.current(target: "en", packs: packs)
    expectEqual(hint.state, .ready, "target ready, another language missing")
    expect(hint.text.contains("Français") && hint.text.contains("not downloaded"), "the other missing one is named: «\(hint.text)»")
    expectEqual(hint.toDownload, ["fr"], "D downloads the others too")
    hint = LanguageHint.current(target: "zz-gone", packs: packs)
    expectEqual(hint.target, "en", "a stale saved target falls back to the first language, like the popup does")
    packs.status = [:]
    expectEqual(LanguageHint.current(target: "en", packs: packs).state, .checking, "unknown yet → neutral, never a false alarm")

    let overlay = OverlayWindow(screen: NSScreen.screens[0])
    overlay.show(LanguageHint(target: "uk", state: .missing))
    overlay.show(LanguageHint(target: "uk", state: .ready))
    let pills = overlay.selection.subviews.compactMap { $0 as? PassThroughHostingView<LanguageHintView> }
    expectEqual(pills.count, 1, "the pill is updated in place, not stacked")
    if let pill = pills.first {
        expect(pill.frame.width > 80 && pill.frame.maxY <= overlay.selection.bounds.height, "the pill sits on the screen, below the menu bar (\(pill.frame))")
        expect(abs(pill.frame.midX - overlay.selection.bounds.midX) < 1, "centred")
        expect(pill.hitTest(NSPoint(x: pill.frame.midX, y: pill.frame.midY)) == nil, "clicks go through the pill to the selection")
    }
    overlay.close()

    section("Popup — a language that isn't downloaded")
    let m = TranslationModel()
    var asked: [String]?
    m.onDownload = { asked = $0 }
    m.checkPair = { _, _, _ in .supported }
    m.findMissing = { _, _ in ["ja"] }
    m.target = "en"
    let historyBefore = History.shared.items.count
    m.load("今日はいい天気ですね。散歩に行きましょう。")
    expect(spin { !m.busy }, "doesn't stay loading")
    expectEqual(m.problem, .notDownloaded(["ja"]), "explains which language is missing")
    expectEqual(m.config, nil, "never asks macOS to translate (its download prompt can't show in the popup)")
    expectEqual(History.shared.items.count, historyBefore, "nothing half-done goes into the history")
    m.fix()
    expectEqual(asked, ["ja"], "↩ / Download opens the download for exactly that language")
    m.copy()
    expectEqual(NSPasteboard.general.string(forType: .string), m.original, "⌘C copies the recognised text when there's no translation")

    let host = NSHostingView(rootView: PopupView(model: m))
    host.layoutSubtreeIfNeeded()
    expect(host.fittingSize.height > 100, "the popup shows the problem with room for it (\(Int(host.fittingSize.height)) pt)")
    for problem in [TranslationModel.Problem.notDownloaded(["ja", "ko"]), .unsupported, .failed("Network")] {
        m.problem = problem
        host.layoutSubtreeIfNeeded()
        expect(host.fittingSize.height > 80, "renders \(problem)")
    }
    defaults.set(false, forKey: "showOriginal")
    m.problem = .notDownloaded(["ja"])
    let withoutOriginal = NSHostingView(rootView: PopupView(model: m))
    withoutOriginal.layoutSubtreeIfNeeded()
    expect(withoutOriginal.fittingSize.height > 100, "the text is shown even with “show original” off — never an empty popup")
    defaults.removeObject(forKey: "showOriginal")

    section("Popup — unsupported pair, stuck translation, late answers")
    m.checkPair = { _, _, _ in .unsupported }
    m.translate()
    expect(spin { !m.busy }, "unsupported pair: not loading")
    expectEqual(m.problem, .unsupported, "says Apple can't translate this pair")

    m.checkPair = { _, _, _ in .installed }
    m.timeout = .milliseconds(300)
    m.translate()
    expect(m.busy, "installed: translating")
    expect(spin { m.config != nil }, "hands the translation to macOS")
    expect(spin({ !m.busy }, timeout: 2), "gives up when macOS never answers")
    if case .failed = m.problem { expect(true, "and says so, with Try Again") } else { expect(false, "timed out → .failed, got \(String(describing: m.problem))") }
    m.finish("Good weather today.")
    expectEqual(m.problem, nil, "a translation that arrives clears the problem")
    expectEqual(m.translated, "Good weather today.", "and is shown")

    m.checkPair = { _, _, _ in try? await Task.sleep(for: .milliseconds(300)); return .supported }
    m.translate()
    m.checkPair = { _, _, _ in .installed }
    m.timeout = .seconds(30)
    m.select("uk")                                     // the person pressed Tab while the first check ran
    _ = spin({ false }, timeout: 0.6)
    expectEqual(m.problem, nil, "a slow check for the previous language doesn't overwrite the current one")
    expectEqual(m.target, "uk", "still on the language picked last")

    m.checkPair = { _, _, _ in .supported }
    m.load("Hello")
    m.source = "en"; m.target = "en"
    m.translate()
    expectEqual(m.problem, nil, "same language in and out needs no download")
    expectEqual(m.translated, "Hello", "and shows the text as is")

    section("Shared status store — download what a scan needs")
    let store = LanguageDownloads(selected: ["en", "uk"])
    var idle = 0
    store.onIdle = { idle += 1 }
    store.status = ["en": .ready, "uk": .ready]
    store.extra.append("ja")
    expectEqual(store.rows, ["en", "uk", "ja"], "a scanned language joins the list for the download only")
    store.remove("ja")
    expectEqual(store.rows, ["en", "uk"], "and can be removed again")
    expectEqual(defaults.stringArray(forKey: "languages"), ["en", "uk", "fr"], "without touching the saved Tab list")
    let englishOnly = LanguageDownloads(selected: ["en"])
    englishOnly.onIdle = { idle += 1 }
    Task { await englishOnly.ensure(["en"]) }
    expect(spin { idle == 1 }, "nothing to download → done right away (the popup retries at once)")
    expect(englishOnly.isReady("en"), "English alone is ready")

    defaults.set(["de", "fr"], forKey: "languages")
    store.sync()
    expectEqual(store.selected, ["de", "fr"], "follows the list changed in Settings")

    section("Real macOS language status")
    let german = blocking { await LanguageDownloads.pairStatus(source: "de", target: "en", text: "Guten Morgen") }
    expect([.installed, .supported].contains(german), "German → English is known to macOS (\(german))")
    let detected = blocking { await LanguageDownloads.pairStatus(source: nil, target: "en", text: "Guten Morgen, wie geht es dir heute?") }
    expect([.installed, .supported, .unsupported].contains(detected), "works without a detected source too (\(detected))")
    let missing = blocking { await LanguageDownloads.missing(source: "ja", target: "en") }
    let jaInstalled = blocking { await LanguageDownloads.availability("en", "ja") } == .installed
    if jaInstalled { expect(true, "Japanese is downloaded on this Mac") }
    else { expect(missing.first == "ja", "names Japanese as missing (\(missing) — English too on a Mac with nothing downloaded)") }
    let real = TranslationModel()
    real.target = "en"
    defaults.set(["en", "uk"], forKey: "languages")
    real.load("今日はいい天気ですね。散歩に行きましょう。")
    if jaInstalled { expect(spin({ real.config != nil }, timeout: 10), "downloaded → handed to macOS to translate") }
    else {
        expect(spin({ !real.busy }, timeout: 10), "a real Japanese scan doesn't hang")
        expectEqual(real.problem, .notDownloaded(missing), "not downloaded → the popup offers Download")
        expectEqual(real.config, nil, "and macOS is never asked to translate it")
    }
}
