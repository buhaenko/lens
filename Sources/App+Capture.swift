// Scan flow: selection overlay → screen capture → text recognition → popup.

import AppKit
import Carbon.HIToolbox

extension AppDelegate {
    @objc func capture() {
        if capturing {
            if !overlays.isEmpty { selectionFinished(nil); return }             // the same key again closes the selection
            guard Date().timeIntervalSince(captureStartedAt) > 15 else { return }   // a scan is still running
            NSLog("Lensy: the last scan never finished — starting over")
        }
        capturing = true
        captureStartedAt = Date()
        hidePopup()
        popover.performClose(nil)

        // Lensy has to be the active app to own the cursor — over full-screen videos and games too.
        // The app you were in gets focus back as soon as the selection is done.
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front == .current ? nil : front
        NSApp.activate(ignoringOtherApps: true)

        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen)
            window.selection.onDone = { [weak self] rect in self?.selectionFinished(rect) }
            window.orderFrontRegardless()
            overlays.append(window)
        }
        focusOverlayUnderMouse()
        Crosshair.cursor.set()
        showLanguageHint()
        Task { await LanguageDownloads.shared.refresh(); showLanguageHint() }   // a download may have finished meanwhile

        // Esc works even if some other window grabbed the keyboard; D downloads what the hint says is missing
        overlayKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = Int(event.keyCode)
            let handled: Bool = MainActor.assumeIsolated {
                guard let self else { return false }
                if code == kVK_Escape { self.selectionFinished(nil); return true }
                let missing = LanguageHint.current(target: self.model.target).toDownload
                guard code == kVK_ANSI_D, !missing.isEmpty else { return false }
                self.selectionFinished(nil)
                self.openIntro(download: missing)
                return true
            }
            return handled ? nil : event
        }
        // Watchdog: if anything covers the overlay, steals focus or swaps the cursor, take it back.
        overlayWatchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepOverlayOnTop() }
        }
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            overlayObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keepOverlayOnTop() }
            })
        }
        // a display was plugged in or out: the overlay no longer matches the screens
        overlayObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.selectionFinished(nil) }
        })
    }

    /// The pill at the top of every screen: which language this scan translates into, and whether it's downloaded.
    func showLanguageHint() {
        let hint = LanguageHint.current(target: model.target)
        overlays.forEach { $0.show(hint) }
    }

    /// Back on top, focused, with the crosshair.
    func keepOverlayOnTop() {
        guard !overlays.isEmpty else { return }
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        overlays.forEach { $0.orderFrontRegardless() }
        if !overlays.contains(where: \.isKeyWindow) { focusOverlayUnderMouse() }
        Crosshair.cursor.set()
    }

    private func focusOverlayUnderMouse() {
        let mouse = NSEvent.mouseLocation
        if let window = overlays.first(where: { $0.frame.contains(mouse) }) ?? overlays.first {
            window.makeKey()
            window.makeFirstResponder(window.contentView)
        }
    }

    func selectionFinished(_ rect: NSRect?) {
        guard !overlays.isEmpty else { return }
        overlayWatchdog?.invalidate()
        overlayWatchdog = nil
        if let monitor = overlayKeyMonitor { NSEvent.removeMonitor(monitor) }
        overlayKeyMonitor = nil
        overlayObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        overlayObservers.removeAll()
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        NSCursor.arrow.set()
        previousApp?.activate()
        previousApp = nil
        guard let rect else { capturing = false; return }
        // let the overlay leave the screen first, then grab exactly that rect
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { self.scan(rect) }
    }

    private func scan(_ rect: NSRect) {
        Task { @MainActor in
            let image = await captureScreen(rect)
            capturing = false
            guard let image else {
                NSSound.beep()
                if !CGPreflightScreenCaptureAccess() { openSettings() }   // show what's missing
                return
            }
            let text = await recognize(image)
            guard !text.isEmpty else { NSSound.beep(); return }
            lastAnchor = rect
            model.load(text)
            showPopup(below: rect)
        }
    }
}
