// Lensy tests — compiled together with main.swift (-D TESTING). Run: ./test.sh
import Cocoa
import Vision
import Translation
import ScreenCaptureKit
import CryptoKit
import Carbon.HIToolbox

/// Renders text into a white image (like a screenshot of a document) for OCR tests.
func renderText(_ text: String, size: CGFloat = 26, width: CGFloat = 900) -> CGImage {
    let font = NSFont.systemFont(ofSize: size)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    let bounds = (text as NSString).boundingRect(with: NSSize(width: width - 40, height: 2000), options: [.usesLineFragmentOrigin], attributes: attrs)
    let h = ceil(bounds.height) + 40
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(h * 2), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width, height: h).fill()
    (text as NSString).draw(with: NSRect(x: 20, y: 20, width: width - 40, height: h - 40), options: [.usesLineFragmentOrigin], attributes: attrs)
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
}

func normalized(_ s: String) -> String {
    s.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
        .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
}

/// Share of expected words that appear in the OCR output (robust to tiny OCR differences).
func wordRecall(_ got: String, _ expected: String) -> Double {
    let g = Set(normalized(got).split(separator: " ")), e = normalized(expected).split(separator: " ")
    return e.isEmpty ? 1 : Double(e.filter { g.contains($0) }.count) / Double(e.count)
}

func blocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
    let box = UnsafeMutableTransferBox<T?>(nil)
    let sem = DispatchSemaphore(value: 0)
    Task.detached { box.value = await work(); sem.signal() }
    while sem.wait(timeout: .now() + 0.01) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    return box.value!
}
@discardableResult func shell(_ tool: String, _ args: String...) -> Bool {
    let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit(); return p.terminationStatus == 0
}
final class UnsafeMutableTransferBox<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

@MainActor func runTests() -> Never {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lens-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defaults.removeObject(forKey: "languages"); defaults.removeObject(forKey: "tapKey"); defaults.removeObject(forKey: "rightCommand")
    History.shared = History(url: tmp.appendingPathComponent("shared-history.json"))   // never the user's real history

    // ───────────────────────── unit
    section("assembleLines — OCR lines → text")
    expectEqual(assembleLines([]), "", "empty input → empty string")
    expectEqual(assembleLines([("   ", CGRect(x: 0, y: 0.5, width: 0.5, height: 0.05))]), "", "whitespace-only lines are dropped")
    let two = [("second line", CGRect(x: 0.05, y: 0.40, width: 0.6, height: 0.08)),
               ("First line", CGRect(x: 0.05, y: 0.50, width: 0.6, height: 0.08))]
    expectEqual(assembleLines(two), "First line second line", "lines are ordered top → bottom and joined with a space")
    let hyph = [("infor-", CGRect(x: 0.05, y: 0.50, width: 0.3, height: 0.08)), ("mation here", CGRect(x: 0.05, y: 0.40, width: 0.3, height: 0.08))]
    expectEqual(assembleLines(hyph), "information here", "hyphenated word across lines is re-joined")
    let compound = [("Jean-", CGRect(x: 0.05, y: 0.50, width: 0.3, height: 0.08)), ("Paul went", CGRect(x: 0.05, y: 0.40, width: 0.3, height: 0.08))]
    expectEqual(assembleLines(compound), "Jean-Paul went", "compound across lines keeps its hyphen, no stray space")
    let paras = [("Title", CGRect(x: 0.05, y: 0.80, width: 0.3, height: 0.06)), ("Body text", CGRect(x: 0.05, y: 0.40, width: 0.6, height: 0.06))]
    expectEqual(assembleLines(paras), "Title\n\nBody text", "a big vertical gap starts a new paragraph")
    let cols = [("Left", CGRect(x: 0.02, y: 0.50, width: 0.2, height: 0.06)), ("Right", CGRect(x: 0.60, y: 0.43, width: 0.2, height: 0.06))]
    expect(assembleLines(cols).contains("\n\n"), "a big horizontal jump (another column) starts a new paragraph")

    section("Updates")
    expect(Updater.isNewer("1.2.1", than: "1.2.0") && Updater.isNewer("1.2.10", than: "1.2.9") && Updater.isNewer("1.3", than: "1.2.9"), "newer versions compare numerically")
    expect(!Updater.isNewer("1.2.0", than: "1.2.0") && !Updater.isNewer("1.1.9", than: "1.2.0") && !Updater.isNewer("1.2", than: "1.2.0"), "same or older is never an update")
    expect(!Updater.isNewer("2.0-beta", than: "1.0") && !Updater.isRelease("ci") && !Updater.isRelease("0.0.0-dev"), "pre-releases and dev builds are ignored")
    let feedJSON = #"{"tag_name":"v1.4.0","assets":[{"name":"Lensy.dmg","browser_download_url":"https://x/Lensy.dmg"},{"name":"Lensy.zip","browser_download_url":"https://x/Lensy.zip"},{"name":"Lensy.zip.sig","browser_download_url":"https://x/Lensy.zip.sig"}]}"#
    expectEqual(Updater.parse(Data(feedJSON.utf8)), Updater.Release(version: "1.4.0", archive: URL(string: "https://x/Lensy.zip")!, signature: URL(string: "https://x/Lensy.zip.sig")!), "GitHub release JSON → version, archive, signature")
    expect(Updater.parse(Data(feedJSON.replacingOccurrences(of: "Lensy.zip.sig", with: "other").utf8)) == nil, "a release without a signature is never installed")
    expect(Data(base64Encoded: Updater.publicKey).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) } != nil, "the built-in public key is a valid Ed25519 key")

    let line = { (state: Updater.State) in Updater.menuLine(state, version: "1.2.1") }
    expectEqual(line(.upToDate).title, "Lensy Is Up to Date", "menu: up to date")
    expectEqual(line(.upToDate).subtitle, "1.2.1 is the latest version", "menu: says which version is the latest")
    expect(line(.available("1.3.0")).title == "Update to Lensy 1.3.0…" && line(.available("1.3.0")).highlighted, "menu: a new version stands out")
    expect(!line(.checking).enabled && !line(.installing("1.3.0")).enabled, "menu: no double clicks while checking or installing")
    expect(!Updater.menuLine(.unknown, version: "dev", enabled: false).enabled, "menu: development builds can't update")
    for symbol in [Updater.State.unknown, .checking, .upToDate, .failed, .available("2"), .installing("2")].map({ line($0).symbol }) {
        expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "menu icon exists: \(symbol)")
    }
    let feedFile = tmp.appendingPathComponent("feed.json")
    try? Data(feedJSON.utf8).write(to: feedFile)
    let foundRelease = blocking { await Updater.shared.refresh(feed: feedFile) }
    expect(foundRelease?.version == "1.4.0" && Updater.shared.state == .available("1.4.0"), "check finds a newer release → “Update to Lensy 1.4.0…”")
    try? Data(feedJSON.replacingOccurrences(of: "v1.4.0", with: "v0").utf8).write(to: feedFile)
    _ = blocking { await Updater.shared.refresh(feed: feedFile) }
    expectEqual(Updater.shared.state, .upToDate, "same version → “Lensy Is Up to Date”")
    _ = blocking { await Updater.shared.refresh(feed: tmp.appendingPathComponent("missing.json")) }
    expectEqual(Updater.shared.state, .failed, "no connection → “Couldn’t connect — try again”")

    // end to end on a fake bundle: sign → "download" (file://) → verify → unpack → install over an older copy
    let key = Curve25519.Signing.PrivateKey(), pub = key.publicKey.rawRepresentation.base64EncodedString()
    let testID = "com.serhii.Lensy.updatetest"
    func fakeApp(_ dir: URL, version: String, id: String = testID) -> URL {
        let app = dir.appendingPathComponent("Lensy.app")
        try? FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try? FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/Lensy").path)
        (["CFBundleIdentifier": id, "CFBundleExecutable": "Lensy", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version] as NSDictionary)
            .write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
        shell("/usr/bin/codesign", "--force", "-s", "-", app.path)
        return app
    }
    func release(_ name: String, version: String, bundleVersion: String? = nil, id: String = testID, tamper: Bool = false) -> Updater.Release {
        let dir = tmp.appendingPathComponent("rel-\(name)")
        let app = fakeApp(dir, version: bundleVersion ?? version, id: id)
        let zip = dir.appendingPathComponent("Lensy.zip")
        shell("/usr/bin/ditto", "-c", "-k", "--keepParent", app.path, zip.path)
        var data = (try? Data(contentsOf: zip)) ?? Data()
        let sig = (try? key.signature(for: data).base64EncodedString()) ?? ""
        if tamper { data[data.count / 2] ^= 0xFF; try? data.write(to: zip) }
        try? Data(sig.utf8).write(to: dir.appendingPathComponent("Lensy.zip.sig"))
        return Updater.Release(version: version, archive: zip, signature: dir.appendingPathComponent("Lensy.zip.sig"))
    }
    let installed = fakeApp(tmp.appendingPathComponent("Applications"), version: "1.0.0")
    func prepare(_ r: Updater.Release, publicKey: String? = nil) -> Result<URL, Error> {
        let pk = publicKey ?? pub
        return blocking { do { return .success(try await Updater.prepare(r, replacing: installed, publicKey: pk, bundleID: testID, current: "1.0.0")) } catch { return .failure(error) } }
    }
    func failure(_ result: Result<URL, Error>) -> String { if case .failure(let e) = result { return "\(e)" }; return "success" }
    let good = prepare(release("good", version: "9.9.9"))
    if case .success(let staged) = good {
        expect((try? Updater.install(staged, over: installed)) != nil, "the new bundle replaces the installed one")
        expectEqual(NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String, "9.9.9", "installed copy is now the new version")
        expect(shell("/usr/bin/codesign", "--verify", "--strict", installed.path), "installed copy keeps a valid signature")
    } else { expect(false, "a correctly signed update is accepted: \(failure(good))") }
    expectEqual(failure(prepare(release("tampered", version: "9.9.9", tamper: true))), "badSignature", "a modified archive is rejected")
    expectEqual(failure(prepare(release("otherkey", version: "9.9.9"), publicKey: Updater.publicKey)), "badSignature", "an archive signed with another key is rejected")
    expectEqual(failure(prepare(release("otherapp", version: "9.9.9", id: "com.evil.App"))), "badArchive", "another app's bundle is rejected")
    expectEqual(failure(prepare(release("mismatch", version: "9.9.9", bundleVersion: "1.0.0"))), "badArchive", "a bundle whose version doesn't match the release is rejected (no downgrades)")

    section("Selection overlay — always on top")
    if let screen = NSScreen.main {
        let overlay = OverlayWindow(screen: screen)
        expect(overlay.level.rawValue >= Int(CGShieldingWindowLevel()), "level is the top one (\(overlay.level.rawValue)) — above full-screen video, menus and other overlays")
        expect(overlay.level > .screenSaver && overlay.level > .popUpMenu, "above screen-saver and pop-up menu levels")
        expect(overlay.collectionBehavior.contains(.canJoinAllSpaces) && overlay.collectionBehavior.contains(.fullScreenAuxiliary), "shows on every Space, including full-screen apps")
        expect(!overlay.hidesOnDeactivate, "doesn't vanish if another app grabs focus")
        expect(overlay.canBecomeKey && overlay.acceptsMouseMovedEvents, "takes the keyboard (Esc) and mouse moves")
        expectEqual(overlay.frame, screen.frame, "covers the whole screen")
        let view = overlay.selection
        var result: NSRect?? = .none
        view.onDone = { result = .some($0) }
        let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: UInt16(kVK_Escape))!
        view.keyDown(with: esc)
        expect(result == .some(nil), "Esc cancels")
    } else { skip("overlay", "no screen") }

    section("Selection pointer")
    expect(Crosshair.cursor.image.size == NSSize(width: 24, height: 24) && Crosshair.cursor.hotSpot == NSPoint(x: 12, y: 12), "a small cross that aims at its centre")
    expect(Crosshair.image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil, "draws")

    section("Renamed from Lens — nothing is lost")
    do {
        let suite = "lensy-migration-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let oldDir = support.appendingPathComponent("Lens")
        try? FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try? Data("[]".utf8).write(to: oldDir.appendingPathComponent("history.json"))
        store.set(["en"], forKey: "languages")
        Migration.fromLens(defaults: store, old: ["languages": ["uk", "de"], "tapKey": "rightCommand", "onboarded": true], support: support)
        expectEqual(store.string(forKey: "tapKey"), "rightCommand", "old settings come along")
        expectEqual(store.stringArray(forKey: "languages"), ["en"], "settings already made in Lensy win")
        expect(FileManager.default.fileExists(atPath: support.appendingPathComponent("Lensy/history.json").path), "history moves to the new folder")
        expect(!FileManager.default.fileExists(atPath: oldDir.path), "the old folder is gone")
        store.removeObject(forKey: "tapKey")
        Migration.fromLens(defaults: store, old: ["tapKey": "rightCommand"], support: support)
        expect(store.object(forKey: "tapKey") == nil, "runs only once")
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: support)
    }

    section("Intro — choose & download languages")
    let savedLanguages = defaults.stringArray(forKey: "languages")
    let dl = LanguageDownloads(selected: ["uk", "de", "en"])
    expectEqual(dl.pairSource(for: "uk"), "en", "a language is downloaded as a pair with English")
    expectEqual(dl.pairSource(for: "en"), "uk", "English pairs with another chosen language")
    expect(LanguageDownloads(selected: ["en"]).pairSource(for: "en") == nil, "English alone needs no download")
    dl.status = ["uk": .ready, "de": .needed, "en": .failed]
    expectEqual(dl.needed, ["de", "en"], "“Download N languages” counts missing and failed ones")
    dl.remove("de")
    expectEqual(dl.selected, ["uk", "en"], "a language can be removed")
    LanguageDownloads(selected: ["en"]).remove("en")
    expectEqual(LanguageDownloads(selected: ["en"]).selected, ["en"], "the last language can't be removed")
    let real = LanguageDownloads(selected: ["uk", "en"])
    _ = blocking { await real.refresh() }
    expect(["uk", "en"].allSatisfy { [.ready, .needed, .unsupported].contains(real.status[$0]) }, "real status from macOS: uk \(String(describing: real.status["uk"])), en \(String(describing: real.status["en"]))")
    if let savedLanguages { defaults.set(savedLanguages, forKey: "languages") } else { defaults.removeObject(forKey: "languages") }

    section("Edit shortcuts in text fields")
    installEditMenu()
    let edit = NSApplication.shared.mainMenu?.items.first { $0.submenu?.title == "Edit" }?.submenu
    for (key, action) in [("a", "selectAll:"), ("c", "copy:"), ("v", "paste:"), ("x", "cut:"), ("z", "undo:")] {
        let item = edit?.items.first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == .command }
        expect(item?.action.map(NSStringFromSelector) == action, "⌘\(key.uppercased()) → \(action)")
    }

    section("makeLang — international language codes")
    expectEqual(makeLang("en").code, "EN", "en → EN")
    expectEqual(makeLang("uk").code, "UK", "uk → UK (ISO 639-1, not a country code)")
    expectEqual(makeLang("pt-BR").code, "PT", "pt-BR → PT")
    expectEqual(makeLang("ja").code, "JA", "ja → JA")
    expect(makeLang("de").name.hasPrefix("Deutsch"), "names are shown in their own language (de → Deutsch)")
    expect(makeLang("fr").name.first?.isUppercase == true, "names are capitalised (français → Français)")

    section("languages list defaults & overrides")
    expect(!langs.isEmpty, "default list is never empty")
    expect(langs.contains { $0.id == "en" }, "English is always in the default list")
    expect(langs.count <= 4, "default list is short (≤ 4)")
    defaults.set(["fr", "ja"], forKey: "languages")
    expectEqual(langs.map(\.id), ["fr", "ja"], "user's own list (and order) wins")
    defaults.set([String](), forKey: "languages")
    expect(!langs.isEmpty, "an empty saved list falls back to defaults")
    defaults.removeObject(forKey: "languages")

    section("Model — language cycling")
    defaults.set(["en", "de", "fr"], forKey: "languages")
    let m = TranslationModel()
    m.original = "Hello there"; m.source = "en"; m.target = "de"
    m.cycle(1); expectEqual(m.target, "fr", "Tab → next language")
    m.cycle(1); expectEqual(m.target, "de", "Tab skips the source language (en) and wraps around")
    m.cycle(-1); expectEqual(m.target, "fr", "⇧Tab goes back")
    defaults.set(["de", "de"], forKey: "languages")
    m.source = "de"; m.target = "de"; m.cycle(1)
    expect(true, "duplicate / all-source list doesn't hang")
    defaults.set(["en", "de"], forKey: "languages")
    m.load("Guten Morgen, wie geht es dir heute?")
    expectEqual(m.source, "de", "load() detects the source language")
    expect(m.target != "de", "load() never targets the source language")
    defaults.removeObject(forKey: "languages")

    section("TapKey & shortcuts")
    expectEqual(TapKey.current, .rightCommand, "default quick-scan key is right ⌘")
    defaults.set(false, forKey: "rightCommand")
    expectEqual(TapKey.current, .off, "legacy 'rightCommand = false' maps to Off")
    defaults.set("rightOption", forKey: "tapKey")
    expectEqual(TapKey.current, .rightOption, "explicit choice wins over the legacy flag")
    expectEqual(TapKey.rightOption.keyCode, 61, "right ⌥ key code")
    expectEqual(TapKey.rightShift.flag, NSEvent.ModifierFlags.shift, "right ⇧ flag")
    expect(TapKey.off.keyCode == nil, "Off has no key")
    expect(shortcutHint().contains(ScanHotKey.label), "hint mentions the scan shortcut")
    defaults.set("off", forKey: "tapKey")
    expect(shortcutHint().hasPrefix("Press"), "hint without quick-scan key says 'Press …'")
    defaults.removeObject(forKey: "tapKey"); defaults.removeObject(forKey: "rightCommand")
    expectEqual(ScanHotKey.label, "⇧⌘7", "default scan shortcut")

    section("History — storage")
    let url = tmp.appendingPathComponent("history.json")
    let h = History(url: url)
    expect(h.items.isEmpty, "starts empty without a file")
    h.upsert(Scan(original: "A", translated: "a", source: "en", target: "de"))
    h.upsert(Scan(original: "B", translated: "b", source: "en", target: "de"))
    h.upsert(Scan(original: "A", translated: "a2", source: "en", target: "fr"))
    expectEqual(h.items.map(\.original), ["A", "B"], "re-scanning the same text moves it to the top, no duplicate")
    var s1 = h.items[0]; s1.translated = "updated"; h.upsert(s1)
    expectEqual(History(url: url).items.first?.translated, "updated", "updates by id are persisted and reloaded")
    defaults.set(25, forKey: "historyLimit")
    for i in 0..<40 { h.upsert(Scan(original: "t\(i)", translated: "x", source: nil, target: "en")) }
    expectEqual(h.items.count, 25, "history respects the size limit")
    defaults.removeObject(forKey: "historyLimit")
    try? Data("{not json".utf8).write(to: url)
    expect(History(url: url).items.isEmpty, "corrupted history file → empty list, no crash")
    h.clear(); expect(History(url: url).items.isEmpty, "clear() empties the file")

    section("History — pinning & search")
    let ph = History(url: tmp.appendingPathComponent("pins.json"))
    ph.upsert(Scan(original: "Notausgang", translated: "Emergency exit", source: "de", target: "en"))
    ph.upsert(Scan(original: "Straße", translated: "Street", source: "de", target: "en"))
    ph.togglePin(ph.items.first { $0.original == "Notausgang" }!.id)
    expectEqual(ph.pinned.map(\.original), ["Notausgang"], "pin moves a scan into the pinned list")
    defaults.set(25, forKey: "historyLimit")
    for i in 0..<40 { ph.upsert(Scan(original: "x\(i)", translated: "y", source: nil, target: "en")) }
    expect(ph.pinned.count == 1 && ph.recent.count == 25, "the size limit never drops pinned scans")
    defaults.removeObject(forKey: "historyLimit")
    ph.upsert(Scan(original: "Notausgang", translated: "Emergency exit", source: "de", target: "fr"))
    expect(ph.items.first?.pinned == true, "re-scanning a pinned text keeps it pinned")
    ph.clear()
    expectEqual(History(url: tmp.appendingPathComponent("pins.json")).items.map(\.original), ["Notausgang"], "Clear keeps pinned scans (and that is saved)")
    let sample = Scan(original: "Größe", translated: "Size", source: "de", target: "en")
    expect(sample.matches("size") && sample.matches("grö") && sample.matches("gro"), "search ignores case and accents (gro → Größe)")
    expect(sample.matches("") && sample.matches("  "), "empty search matches everything")
    expect(!sample.matches("street"), "search doesn't match unrelated text")
    let legacy = tmp.appendingPathComponent("legacy.json")
    try? Data(#"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","original":"A","translated":"B","source":"en","target":"de","date":"2026-11-20T10:00:00Z"}]"#.utf8).write(to: legacy)
    let old = History(url: legacy)
    expect(old.items.count == 1 && old.items[0].pinned == false, "old history files (before pinning) still load")

    section("History filters")
    let none = HistoryFilter()
    expect(none.reasonToSkip("Hallo", source: "de") == nil && none.activeCount == 0, "no filters → everything is kept")
    let langFilter = HistoryFilter(skipLanguages: ["uk", "en"])
    expectEqual(langFilter.reasonToSkip("Привіт, як справи?", source: "uk"), .language("uk"), "skipped language isn't saved")
    expectEqual(langFilter.reasonToSkip("Hello", source: "en-US"), .language("en"), "regional variants count (en-US → en)")
    expect(langFilter.reasonToSkip("Guten Morgen", source: "de") == nil, "other languages are kept")
    expect(langFilter.reasonToSkip("???", source: nil) == nil, "unknown language isn't skipped by the language filter")
    let short = HistoryFilter(minLength: 4)
    expectEqual(short.reasonToSkip(" ok ", source: "en"), .tooShort, "text shorter than the minimum is skipped (whitespace ignored)")
    expect(short.reasonToSkip("Haus", source: "de") == nil, "text at the minimum is kept")
    let numbers = HistoryFilter(skipNumbers: true)
    for text in ["€ 12,99", "08:30", "#A7F3-22", "1.234.567", "  "] {
        expectEqual(numbers.reasonToSkip(text, source: nil), .numbers, "numbers filter skips «\(text)»")
    }
    for text in ["Seite 3 von 12", "Kapitel 7: Die Rückkehr", "Größe"] {
        expect(numbers.reasonToSkip(text, source: nil) == nil, "numbers filter keeps real words: «\(text)»")
    }
    let priv = HistoryFilter(skipPrivate: true)
    for text in ["Schreib mir an lena@example.com", "mehr auf https://example.org/a", "Karte: 4111 1111 1111 1111",
                 "IBAN DE89 3704 0044 0532 0130 00", "Ruf an: +49 30 1234567"] {
        expectEqual(priv.reasonToSkip(text, source: "de"), .privateInfo, "private filter skips «\(text.prefix(26))»")
    }
    expect(priv.reasonToSkip("Der Zug fährt um 12 Uhr ab", source: "de") == nil, "ordinary sentences with numbers are kept")
    expect(!HistoryFilter.containsCardNumber("Bestellnummer 1234 5678 9012 3456"), "16 digits failing the Luhn check aren't a card")
    let words = HistoryFilter(blockedWords: HistoryFilter.words(from: " Passwort , invoice,, "))
    expectEqual(words.blockedWords, ["Passwort", "invoice"], "word list is split on commas and trimmed")
    expectEqual(words.reasonToSkip("Dein PASSWORT wurde geändert", source: "de"), .blockedWord("Passwort"), "blocked words ignore case")
    expectEqual(HistoryFilter(blockedWords: ["uber"]).reasonToSkip("Über uns", source: "de"), .blockedWord("uber"), "…and accents")

    let saved = HistoryFilter.current
    HistoryFilter.current = HistoryFilter(skipLanguages: ["fr"], minLength: 10, skipNumbers: true, skipPrivate: true, blockedWords: ["x"])
    expectEqual(HistoryFilter.current, HistoryFilter(skipLanguages: ["fr"], minLength: 10, skipNumbers: true, skipPrivate: true, blockedWords: ["x"]),
                "filters survive a round trip through settings")
    expectEqual(HistoryFilter.current.activeCount, 5, "active filters are counted for the Settings summary")

    let fh = History(url: tmp.appendingPathComponent("filter-history.json"))
    fh.upsert(Scan(original: "Bonjour tout le monde", translated: "Hello everyone", source: "fr", target: "en"))
    fh.upsert(Scan(original: "Merci beaucoup", translated: "Thanks a lot", source: "fr", target: "en", pinned: true))
    fh.upsert(Scan(original: "Guten Abend allerseits", translated: "Good evening, everyone", source: "de", target: "en"))
    expectEqual(fh.apply(HistoryFilter(skipLanguages: ["fr"])), 1, "applying filters removes matching saved scans")
    expect(fh.items.map(\.original) == ["Guten Abend allerseits", "Merci beaucoup"], "…but keeps pinned ones and everything else")

    HistoryFilter.current = HistoryFilter(skipLanguages: ["de"])
    let before = History.shared.items.count
    let fm = TranslationModel(); fm.original = "Guten Morgen"; fm.translated = "Good morning"; fm.source = "de"; fm.record()
    expectEqual(History.shared.items.count, before, "a filtered scan is translated but not recorded")
    fm.scanID = UUID(); fm.original = "Bonjour"; fm.translated = "Hello"; fm.source = "fr"; fm.record()
    expectEqual(History.shared.items.count, before + 1, "unfiltered scans are still recorded")
    HistoryFilter.current = saved

    section("Language detection (no hard-coded list)")
    let samples: [(String, String)] = [
        ("The weather is lovely today and we are going to the park.", "en"),
        ("Das Wetter ist heute schön und wir gehen in den Park.", "de"),
        ("Il fait beau aujourd'hui et nous allons au parc.", "fr"),
        ("Hoy hace buen tiempo y vamos al parque.", "es"),
        ("Сьогодні чудова погода, і ми йдемо до парку.", "uk"),
        ("今日は天気が良いので公園に行きます。", "ja"),
        ("Dzisiaj jest ładna pogoda i idziemy do parku.", "pl"),
    ]
    for (text, lang) in samples { expectEqual(detectLanguage(text), lang, "detects \(lang)") }

    // ───────────────────────── integration (real system frameworks)
    section("OCR — Apple Vision on rendered text")
    let hints = recognitionHints()
    let supported = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
    expect(!hints.isEmpty, "recognition hints are not empty")
    expect(hints.allSatisfy { supported.contains($0) }, "every hint is supported by Vision (bad codes would fail the request)")
    let ocrSamples = [
        "Failed to load scene because the asset bundle was built with an incompatible version.",
        "Größe, Übung und Straße — schöne Grüße aus München.",
        "Привіт! Це тест розпізнавання українського тексту.",
        "Où est la bibliothèque? Le café est très célèbre.",
    ]
    for text in ocrSamples {
        let got = blocking { await recognize(renderText(text)) }
        let r = wordRecall(got, text)
        expect(r >= 0.85, "recognised \(Int(r * 100))% of words: «\(text.prefix(28))…»")
    }
    let empty = blocking { await recognize(renderText(" ")) }
    expectEqual(empty, "", "blank image → empty text (no crash)")
    let longText = String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 30)
    let longGot = blocking { await recognize(renderText(longText, size: 16, width: 1400)) }
    expect(longGot.count > 500, "long text is recognised in full (\(longGot.count) chars)")

    section("Translation — Apple Translation (on-device)")
    #if compiler(>=6.2)   // TranslationSession(installedSource:) needs the macOS 26 SDK (Xcode 26)
    if #available(macOS 26.0, *) {
        let status = blocking { await LanguageAvailability().status(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "de")) }
        if status == .installed {
            let out: String? = blocking {
                let s = TranslationSession(installedSource: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "de"))
                return try? await s.translate("Good morning, how are you?").targetText
            }
            expect(out != nil && !(out ?? "").isEmpty, "en → de translation returns text: «\(out ?? "nil")»")
            expect((out ?? "").lowercased().contains("morgen"), "translation looks German")
        } else { skip("en → de translation", "language pack not installed (status \(status))") }
        let supportedLangs = blocking { await LanguageAvailability().supportedLanguages }
        expect(supportedLangs.count >= 15, "Apple Translation offers \(supportedLangs.count) languages for the Add-language menu")
    } else { skip("translation", "needs macOS 26+ for TranslationSession(installedSource:)") }
    #else
    skip("translation", "built with an SDK older than macOS 26")
    #endif

    section("Screen capture — ScreenCaptureKit")
    if CGPreflightScreenCaptureAccess() {
        let main = NSScreen.screens[0].frame
        let img = blocking { await captureScreen(NSRect(x: main.minX + 10, y: main.maxY - 110, width: 200, height: 100)) }
        expect(img != nil, "captures a 200×100 pt rect")
        if let img { expect(img.width >= 200 && img.height >= 100, "captured at native resolution (\(img.width)×\(img.height) px)") }
    } else { skip("screen capture", "the test runner has no Screen Recording permission (Lensy itself does)") }

    try? FileManager.default.removeItem(at: tmp)
    runRobustnessTests()
    finish("Lensy")
}
