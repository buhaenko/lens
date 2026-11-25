// What never gets remembered. Filters only decide what goes into the history — everything is still translated.

import Foundation

struct HistoryFilter: Equatable {
    /// Source languages not worth keeping — usually the ones you already read.
    var skipLanguages: [String] = []
    /// Text with fewer characters than this isn't saved (0 = keep everything).
    var minLength = 0
    /// Prices, codes, timestamps: text that's mostly digits and symbols.
    var skipNumbers = false
    /// Emails, links, phone, card and IBAN numbers.
    var skipPrivate = false
    /// Never save text containing any of these (case- and accent-insensitive).
    var blockedWords: [String] = []

    enum Reason: Equatable {
        case language(String), tooShort, numbers, privateInfo, blockedWord(String)
    }

    /// Why this text shouldn't be saved, or nil to keep it.
    func reasonToSkip(_ text: String, source: String?) -> Reason? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let source, let base = Self.base(source), skipLanguages.contains(where: { Self.base($0) == base }) { return .language(base) }
        if minLength > 0 && text.count < minLength { return .tooShort }
        if skipNumbers && Self.isMostlyNumbers(text) { return .numbers }
        if skipPrivate && Self.containsPrivateInfo(text) { return .privateInfo }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if let word = blockedWords.first(where: { !$0.isEmpty && text.range(of: $0, options: options) != nil }) { return .blockedWord(word) }
        return nil
    }

    func keeps(_ scan: Scan) -> Bool { reasonToSkip(scan.original, source: scan.source) == nil }

    var activeCount: Int {
        [!skipLanguages.isEmpty, minLength > 0, skipNumbers, skipPrivate, !blockedWords.isEmpty].filter { $0 }.count
    }

    // MARK: - Detection

    /// "€ 12,99", "08:30", "#A7F3-22" — fewer than three letters, or letters are under half of the text.
    static func isMostlyNumbers(_ text: String) -> Bool {
        let visible = text.filter { !$0.isWhitespace }
        guard !visible.isEmpty else { return true }
        let letters = visible.filter(\.isLetter).count
        return letters < 3 || Double(letters) / Double(visible.count) < 0.5
    }

    static func containsPrivateInfo(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        let types: NSTextCheckingResult.CheckingType = [.link, .phoneNumber]   // .link covers emails and URLs
        if let detector = try? NSDataDetector(types: types.rawValue), detector.firstMatch(in: text, range: range) != nil { return true }
        return containsCardNumber(text) || text.range(of: iban, options: .regularExpression) != nil
    }

    /// 13–19 digits (spaces or dashes allowed) that pass the Luhn check.
    static func containsCardNumber(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"(?:\d[ -]?){12,18}\d"#) else { return false }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).contains { match in
            let digits = text[Range(match.range, in: text)!].compactMap(\.wholeNumberValue)
            return luhn(digits)
        }
    }

    static func luhn(_ digits: [Int]) -> Bool {
        let sum = digits.reversed().enumerated().reduce(0) { total, item in
            let (index, digit) = item
            guard index % 2 == 1 else { return total + digit }
            return total + (digit * 2 > 9 ? digit * 2 - 9 : digit * 2)
        }
        return sum % 10 == 0
    }

    static let iban = #"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){3,7}(?: ?[A-Z0-9]{1,3})?\b"#

    private static func base(_ id: String) -> String? { Locale.Language(identifier: id).languageCode?.identifier ?? id }
}

// MARK: - Stored in UserDefaults

extension HistoryFilter {
    static var current: HistoryFilter {
        get {
            HistoryFilter(skipLanguages: defaults.stringArray(forKey: "filter.languages") ?? [],
                          minLength: defaults.integer(forKey: "filter.minLength"),
                          skipNumbers: defaults.bool(forKey: "filter.numbers"),
                          skipPrivate: defaults.bool(forKey: "filter.private"),
                          blockedWords: defaults.stringArray(forKey: "filter.words") ?? [])
        }
        set {
            defaults.set(newValue.skipLanguages, forKey: "filter.languages")
            defaults.set(newValue.minLength, forKey: "filter.minLength")
            defaults.set(newValue.skipNumbers, forKey: "filter.numbers")
            defaults.set(newValue.skipPrivate, forKey: "filter.private")
            defaults.set(newValue.blockedWords, forKey: "filter.words")
        }
    }

    /// "password, invoice ,  " → ["password", "invoice"]
    static func words(from list: String) -> [String] {
        list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
