// Screen Recording and Accessibility: checks, prompts, and a shortcut to the right Settings pane.

import AppKit
import ApplicationServices

/// Asking first makes macOS list Lensy in System Settings, so the user only has to flip a switch.
enum Permissions {
    enum Pane: String {
        case screenRecording = "Privacy_ScreenCapture"
        case accessibility = "Privacy_Accessibility"
    }

    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static var accessibility: Bool { AXIsProcessTrusted() }

    /// A real (1×1 px) capture attempt is what makes macOS prompt and list Lensy under Screen Recording.
    static func requestScreen() {
        guard !screenRecording else { return }
        _ = CGRequestScreenCaptureAccess()
        Task { _ = await captureScreen(NSRect(x: 0, y: 0, width: 1, height: 1)) }
    }

    /// Needed for the quick-scan key; this prompt adds Lensy to the Accessibility list.
    static func requestAccessibility() {
        guard !accessibility else { return }
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    /// Ask (so Lensy appears in the list), then open that page of System Settings.
    @MainActor static func guide(to pane: Pane) {
        pane == .screenRecording ? requestScreen() : requestAccessibility()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
