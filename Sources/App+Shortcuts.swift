// Shortcuts: the scan hotkey (Carbon, default ⇧⌘7) and the quick-scan modifier tap (default right ⌘).

import AppKit
import Carbon.HIToolbox

extension AppDelegate {
    // MARK: - Scan hotkey

    func registerHotKey() {
        if !hotKeyHandlerInstalled {
            hotKeyHandlerInstalled = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
                let app = Unmanaged<AppDelegate>.fromOpaque(context!).takeUnretainedValue()
                DispatchQueue.main.async { app.capture() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
            NotificationCenter.default.addObserver(forName: ScanHotKey.changed, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.registerHotKey() }
            }
        }
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        let id = EventHotKeyID(signature: OSType(0x4C454E53), id: 1)   // 'LENS'
        let status = RegisterEventHotKey(UInt32(ScanHotKey.keyCode), UInt32(ScanHotKey.mods), id, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { NSLog("Lensy: scan shortcut %@ is taken by another app (%d)", ScanHotKey.label, status) }
    }

    // MARK: - Quick-scan tap

    /// Listens for the chosen modifier being tapped on its own. NSEvent monitors only need Accessibility
    /// (an event tap would also trigger an Input Monitoring prompt, which blocks other permission prompts).
    func installQuickScanTap() {
        if !askedForAccessibility { askedForAccessibility = true; Permissions.requestAccessibility() }
        guard AXIsProcessTrusted() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.installQuickScanTap() }
            return
        }
        guard tapMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleQuickScan(event) }
        }) { tapMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleQuickScan(event) }
            return event
        }) { tapMonitors.append(local) }
        NSLog("Lensy: quick-scan key active")
    }

    /// A tap = the modifier goes down alone and comes back up within 0.35 s, with nothing else in between.
    private func handleQuickScan(_ event: NSEvent) {
        let key = TapKey.current
        guard event.type == .flagsChanged else {
            if tapStartedAt != nil { tapInterrupted = true }          // ⌘+key, ⌘-click… → not a tap
            return
        }
        let held = event.modifierFlags.intersection([.command, .shift, .option, .control, .function])
        guard let code = key.keyCode, Int(event.keyCode) == code else {
            if tapStartedAt != nil { tapInterrupted = true }          // another modifier joined
            return
        }
        if held == key.flag {
            tapStartedAt = Date(); tapInterrupted = false
        } else if held.isEmpty, let start = tapStartedAt {
            if !tapInterrupted && Date().timeIntervalSince(start) < 0.35 { capture() }
            tapStartedAt = nil
        } else {
            tapInterrupted = true
        }
    }
}
