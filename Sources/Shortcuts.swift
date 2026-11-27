// Scan shortcut (customisable hotkey) and the quick-scan modifier tap.

import AppKit
import Carbon.HIToolbox

/// Modifier you can tap on its own to start a scan.
enum TapKey: String, CaseIterable, Identifiable {
    case off, rightCommand, rightOption, rightShift, rightControl
    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: String(localized: "Off")
        case .rightCommand: String(localized: "Right ⌘")
        case .rightOption: String(localized: "Right ⌥")
        case .rightShift: String(localized: "Right ⇧")
        case .rightControl: String(localized: "Right ⌃")
        }
    }

    var keyCode: Int? {
        switch self {
        case .off: nil
        case .rightCommand: kVK_RightCommand
        case .rightOption: kVK_RightOption
        case .rightShift: kVK_RightShift
        case .rightControl: kVK_RightControl
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .off: []
        case .rightCommand: .command
        case .rightOption: .option
        case .rightShift: .shift
        case .rightControl: .control
        }
    }

    static var current: TapKey {
        if let raw = defaults.string(forKey: "tapKey"), let key = TapKey(rawValue: raw) { return key }
        return (defaults.object(forKey: "rightCommand") as? Bool ?? true) ? .rightCommand : .off   // pre-1.0 setting
    }
}

/// Scan hotkey (default ⇧⌘7) — stored as Carbon key code + modifiers + a display label.
enum ScanHotKey {
    static var keyCode: Int { defaults.object(forKey: "hotKeyCode") as? Int ?? kVK_ANSI_7 }
    static var mods: Int { defaults.object(forKey: "hotKeyMods") as? Int ?? (cmdKey | shiftKey) }
    static var label: String { defaults.string(forKey: "hotKeyLabel") ?? "⇧⌘7" }
    static let changed = Notification.Name("LensHotKeyChanged")
}

/// "Tap right ⌘ or press ⇧⌘7" — whatever the user configured.
func shortcutHint() -> String {
    let tap = TapKey.current
    let key = ScanHotKey.label
    return tap == .off ? String(localized: "Press \(key)") : String(localized: "Tap \(tap.label.lowercased()) or press \(key)")
}
