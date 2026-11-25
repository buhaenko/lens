// Target languages for translation: the user's list, or sensible defaults from the system.

import Foundation

let defaults = UserDefaults.standard

struct Lang: Identifiable, Equatable {
    let id: String      // BCP-47, e.g. "uk", "de", "pt-BR"
    let code: String    // ISO 639-1 shown in the popup, e.g. "UK", "DE", "PT"
    let name: String    // in its own language, e.g. "Українська", "Deutsch"
    var language: Locale.Language { Locale.Language(identifier: id) }
}

func makeLang(_ id: String) -> Lang {
    let base = Locale.Language(identifier: id).languageCode?.identifier ?? id
    let name = Locale(identifier: id).localizedString(forIdentifier: id) ?? id
    return Lang(id: id, code: base.uppercased(), name: name.prefix(1).uppercased() + name.dropFirst())
}

/// Languages Tab cycles through. Default: the system languages plus English, at most four.
var langs: [Lang] {
    if let saved = defaults.stringArray(forKey: "languages"), !saved.isEmpty { return saved.map(makeLang) }
    var ids: [String] = []
    for preferred in Locale.preferredLanguages {
        let code = Locale.Language(identifier: preferred).languageCode?.identifier ?? preferred
        if !ids.contains(code) { ids.append(code) }
    }
    if !ids.contains("en") { ids.append("en") }
    return ids.prefix(4).map(makeLang)
}
