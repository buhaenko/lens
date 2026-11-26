// Lensy used to be called Lens: carry over its settings and history once, so nothing is lost on the rename.

import Foundation

enum Migration {
    static let oldDomain = "com.serhii.Lens"
    static let oldFolder = "Lens"

    /// Copies the old app's settings (unless already done) and moves its history folder. Safe to call on every launch.
    static func fromLens(defaults: UserDefaults = .standard,
                         old: [String: Any]? = UserDefaults.standard.persistentDomain(forName: oldDomain),
                         support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                         newFolder: String = "Lensy") {
        if !defaults.bool(forKey: "migratedFromLens") {
            for (key, value) in old ?? [:] where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
            defaults.set(true, forKey: "migratedFromLens")
        }
        let from = support.appendingPathComponent(oldFolder), to = support.appendingPathComponent(newFolder)
        let fm = FileManager.default
        if fm.fileExists(atPath: from.appendingPathComponent("history.json").path),
           !fm.fileExists(atPath: to.appendingPathComponent("history.json").path) {
            try? fm.createDirectory(at: to, withIntermediateDirectories: true)
            try? fm.moveItem(at: from.appendingPathComponent("history.json"), to: to.appendingPathComponent("history.json"))
            try? fm.removeItem(at: from)
        }
    }
}
