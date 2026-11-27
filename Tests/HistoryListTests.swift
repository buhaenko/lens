// The history popover's behaviour: undo, the two-step Clear, the keyboard, crash reports.

import AppKit
import Carbon.HIToolbox

@MainActor func runHistoryListTests() {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lensy-list-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let history = History(url: folder.appendingPathComponent("h.json"))
    let now = Date()
    let a = Scan(original: "a", translated: "A", source: "de", target: "uk", date: now)
    let b = Scan(original: "b", translated: "B", source: "de", target: "uk", date: now.addingTimeInterval(-60))
    let c = Scan(original: "c", translated: "C", source: "de", target: "uk", date: now.addingTimeInterval(-120), pinned: true)
    for scan in [c, b, a] { history.upsert(scan) }
    let list = HistoryList(history: history)
    var opened: Scan?
    list.open = { opened = $0 }

    section("History — delete with Undo")
    list.remove(b.id)
    expectEqual(history.items.map(\.id), [a.id, c.id], "deleted")
    expectEqual(list.undo?.scans.map(\.id), [b.id], "and Undo is offered")
    expectEqual(list.undo?.text, "Deleted", "saying what happened")
    list.undoLast()
    expectEqual(history.items.map(\.id), [a.id, b.id, c.id], "Undo puts it back in its place")
    expectEqual(History(url: history.url).items.count, 3, "and on disk")
    expect(list.undo == nil, "Undo is used up")
    list.undoDuration = .milliseconds(150)
    list.remove(a.id)
    expect(spin({ list.undo == nil }, timeout: 2), "Undo goes away on its own after a while")
    history.restore([a])
    history.restore([a])
    expectEqual(history.items.filter { $0.id == a.id }.count, 1, "restoring twice doesn't duplicate")

    section("History — Clear asks first")
    list.clear()
    expect(list.confirmingClear, "first click asks")
    expectEqual(history.items.count, 3, "and clears nothing yet")
    list.clear()
    expectEqual(history.items.map(\.id), [c.id], "second click clears the unpinned ones")
    expectEqual(list.undo?.text, "Cleared 2 scans", "and offers Undo")
    list.handleKey(kVK_ANSI_Z, modifiers: .command)
    expectEqual(history.items.count, 3, "⌘Z brings them back")
    list.confirmDuration = .milliseconds(150)
    list.clear()
    expect(spin({ !list.confirmingClear }, timeout: 2), "the question goes away if not confirmed")

    section("History — keyboard")
    list.reset()
    expect(list.handleKey(kVK_DownArrow, modifiers: []), "↓ is handled")
    expectEqual(list.selected, c.id, "↓ picks the first row shown (pinned first)")
    list.handleKey(kVK_DownArrow, modifiers: [])
    list.handleKey(kVK_DownArrow, modifiers: [])
    list.handleKey(kVK_DownArrow, modifiers: [])
    expectEqual(list.selected, b.id, "and stops at the last one")
    list.handleKey(kVK_UpArrow, modifiers: [])
    expectEqual(list.selected, a.id, "↑ goes back")
    list.handleKey(kVK_Return, modifiers: [])
    expectEqual(opened?.id, a.id, "↩ opens it")
    list.handleKey(kVK_ANSI_C, modifiers: .command)
    expectEqual(NSPasteboard.general.string(forType: .string), "A", "⌘C copies its translation")
    list.handleKey(kVK_ANSI_P, modifiers: .command)
    expect(history.items.first { $0.id == a.id }?.pinned == true, "⌘P pins it")
    list.handleKey(kVK_ANSI_P, modifiers: .command)
    list.handleKey(kVK_Delete, modifiers: .command)
    expect(!history.items.contains { $0.id == a.id }, "⌘⌫ deletes it")
    expectEqual(list.selected, b.id, "and the next row is picked")
    list.undoLast()
    list.reset()
    expect(!list.handleKey(kVK_ANSI_C, modifiers: .command), "nothing picked → ⌘C is left to the search field")
    expect(!list.handleKey(kVK_Delete, modifiers: .command), "and so is ⌘⌫")
    expect(!list.handleKey(kVK_ANSI_A, modifiers: []), "typing goes to the search")
    list.query = "B"
    expectEqual(list.visible.map(\.id), [b.id], "search narrows the list")
    opened = nil
    list.handleKey(kVK_Return, modifiers: [])
    expectEqual(opened?.id, b.id, "↩ opens the only match without picking it first")
    list.handleKey(kVK_Escape, modifiers: [])
    expectEqual(list.query, "", "Esc clears the search")

    section("Crash reports")
    let header = #"{"app_name":"Lensy","timestamp":"2026-11-27 15:00:00.00 +0100","app_version":"1.2.2","os_version":"macOS 27.2.1 (26B131)","bug_type":"309"}"#
    let body = #"{"exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},"faultingThread":1,"asi":{"libswiftCore.dylib":["Fatal error: Index out of range"]},"usedImages":[{"name":"Lensy"},{"name":"libswiftCore.dylib"}],"threads":[{"frames":[]},{"triggered":true,"frames":[{"imageIndex":1,"symbol":"_assertionFailure"},{"imageIndex":0,"symbol":"HistoryList.move(_:)"},{"imageIndex":0,"imageOffset":4096}]}]}"#
    let summary = CrashReports.summary(of: header + "\n" + body) ?? ""
    for part in ["Version: 1.2.2 · macOS 27.2.1", "EXC_BREAKPOINT · SIGTRAP", "Index out of range", "1  Lensy  HistoryList.move(_:)", "2  Lensy  0x1000"] {
        expect(summary.contains(part), "the report has «\(part)»")
    }
    expect(!summary.contains("/Users/"), "and no paths")
    expect(CrashReports.summary(of: "garbage") == nil && CrashReports.summary(of: "{}\n[]") == nil, "anything else isn't a crash report")

    let logs = folder.appendingPathComponent("logs")
    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let savedSeen = defaults.object(forKey: "crashReportsSeen")
    defer { if let savedSeen { defaults.set(savedSeen, forKey: "crashReportsSeen") } else { defaults.removeObject(forKey: "crashReportsSeen") } }
    let crashes = CrashReports()
    defaults.removeObject(forKey: "crashReportsSeen")
    try? (header + "\n" + body).write(to: logs.appendingPathComponent("Lensy-2026-11-27-150000.ips"), atomically: true, encoding: .utf8)
    crashes.check(folder: logs, appName: "Lensy")
    expect(crashes.pending == nil, "first run: old crashes aren't brought up")
    defaults.set(Date().addingTimeInterval(-3600), forKey: "crashReportsSeen")
    try? "x".write(to: logs.appendingPathComponent("Other-2026.ips"), atomically: true, encoding: .utf8)
    crashes.check(folder: logs, appName: "Lensy")
    expect(crashes.pending?.contains("EXC_BREAKPOINT") == true, "a new Lensy crash is offered")
    crashes.dismiss()
    crashes.check(folder: logs, appName: "Lensy")
    expect(crashes.pending == nil, "once only")

    section("Interface language")
    let savedLanguage = defaults.string(forKey: "appLanguage")
    defaults.removeObject(forKey: "appLanguage")
    expectEqual(AppLanguage.current, .en, "English until the person picks another")
    defaults.set("pl", forKey: "appLanguage")
    expectEqual(AppLanguage.current, .pl, "the pick is remembered")
    defaults.set("xx", forKey: "appLanguage")
    expectEqual(AppLanguage.current, .en, "a broken setting falls back to English")
    if let savedLanguage { defaults.set(savedLanguage, forKey: "appLanguage") } else { defaults.removeObject(forKey: "appLanguage") }
    expectEqual(AppLanguage.allCases.map(\.rawValue), ["en", "es", "de", "uk", "pl"], "English, Spanish, German, Ukrainian, Polish")
    for language in AppLanguage.allCases where language != .en {
        let strings = "Resources/\(language.rawValue).lproj/Localizable.strings"
        let table = NSDictionary(contentsOfFile: strings) as? [String: String] ?? [:]
        expect(table.count > 150, "\(language.name) is translated (\(table.count) strings)")
        expect(FileManager.default.fileExists(atPath: "Resources/\(language.rawValue).lproj/Localizable.stringsdict"), "with plurals")
    }
    let system = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
    if let system { expectEqual(systemLanguages, system, "the default translation languages come from macOS, not from Lensy's interface language") }
}
