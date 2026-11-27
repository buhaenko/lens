// The language of Lensy's own interface — English by default, chosen on the welcome screen or in Settings.
// macOS picks an app's localization once, at launch, so switching saves the choice and restarts Lensy
// straight back into the window the person was in.

import AppKit

enum AppLanguage: String, CaseIterable, Identifiable {
    case en, es, de, uk, pl
    var id: String { rawValue }

    /// Each language in its own words, so anyone can find theirs.
    var name: String {
        switch self {
        case .en: "English"
        case .es: "Español"
        case .de: "Deutsch"
        case .uk: "Українська"
        case .pl: "Polski"
        }
    }

    static var current: AppLanguage { AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .en }

    /// Before anything is shown: make macOS load the chosen localization (English unless the person picked another).
    static func applyAtLaunch() {
        defaults.set([current.rawValue], forKey: "AppleLanguages")
    }

    /// Which window to show again after a language switch, and when it was asked for.
    static let reopenKey = "reopenAfterLanguageSwitch"

    /// Saves the choice and restarts Lensy into `window` ("intro" or "settings").
    @MainActor static func switchTo(_ language: AppLanguage, reopening window: String) {
        guard language != current else { return }
        defaults.set(language.rawValue, forKey: "appLanguage")
        defaults.set([language.rawValue], forKey: "AppleLanguages")
        defaults.set(window, forKey: reopenKey)
        defaults.synchronize()
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 0.7; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    /// On launch after a switch: the window to bring back (once).
    static func takeReopen() -> String? {
        guard let window = defaults.string(forKey: reopenKey) else { return nil }
        defaults.removeObject(forKey: reopenKey)
        return window
    }
}

/// The person's languages from System Settings — not Lensy's own interface language, which overrides
/// Locale.preferredLanguages inside the app. Used for the default translation languages and recognition hints.
var systemLanguages: [String] {
    UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String] ?? Locale.preferredLanguages
}
