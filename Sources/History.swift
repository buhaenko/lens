// Persistent history of scans (~/Library/Application Support/Lensy/history.json), with pinning and search.

import Foundation
import Combine

struct Scan: Codable, Identifiable, Equatable {
    var id = UUID()
    var original: String
    var translated: String
    var source: String?
    var target: String
    var date = Date()
    var pinned = false

    init(id: UUID = UUID(), original: String, translated: String, source: String?, target: String, date: Date = Date(), pinned: Bool = false) {
        self.id = id; self.original = original; self.translated = translated
        self.source = source; self.target = target; self.date = date; self.pinned = pinned
    }

    /// Files written before pinning existed have no `pinned` key.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        original = try c.decode(String.self, forKey: .original)
        translated = try c.decode(String.self, forKey: .translated)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        target = try c.decode(String.self, forKey: .target)
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }

    /// Case- and accent-insensitive match on the translation or the original.
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return translated.range(of: q, options: options) != nil || original.range(of: q, options: options) != nil
    }
}

@MainActor final class History: ObservableObject {
    /// The app's history. Tests point this at a temporary file before anything is recorded.
    static var shared = History()

    /// "Lensy" — or the renamed copy's own name (scripts/e2e.sh), so a test run never touches the real history.
    nonisolated static var folderName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Lensy" }

    nonisolated static let defaultURL: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(folderName)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("history.json")
    }()

    @Published private(set) var items: [Scan] = []
    let url: URL

    var pinned: [Scan] { items.filter(\.pinned) }
    var recent: [Scan] { items.filter { !$0.pinned } }

    init(url: URL = History.defaultURL) {
        self.url = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url) {
            items = (try? decoder.decode([Scan].self, from: data)) ?? []    // unreadable file → start fresh
        }
    }

    /// Adds a scan, or updates it (same id). Scanning the same text again moves it to the top (and keeps its pin).
    func upsert(_ scan: Scan) {
        if let index = items.firstIndex(where: { $0.id == scan.id }) {
            items[index] = scan
        } else {
            var scan = scan
            if let previous = items.first(where: { $0.original == scan.original }) { scan.pinned = previous.pinned }
            items.removeAll { $0.original == scan.original }
            items.insert(scan, at: 0)
        }
        trim()
        save()
    }

    func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].pinned.toggle()
        trim()
        save()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    /// Clears everything except pinned scans.
    func clear() {
        items.removeAll { !$0.pinned }
        save()
    }

    /// Removes unpinned scans the filter wouldn't save. Returns how many were removed.
    @discardableResult func apply(_ filter: HistoryFilter) -> Int {
        let before = items.count
        items.removeAll { !$0.pinned && !filter.keeps($0) }
        if items.count != before { save() }
        return before - items.count
    }

    /// The limit applies to unpinned scans only — pinned ones stay until unpinned.
    private func trim() {
        let limit = defaults.object(forKey: "historyLimit") as? Int ?? 100
        var kept = 0
        items.removeAll { scan in
            if scan.pinned { return false }
            kept += 1
            return kept > limit
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(items) { try? data.write(to: url, options: .atomic) }
    }
}
