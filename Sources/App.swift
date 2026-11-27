// App delegate: menu bar item, history popover, settings window, single-instance handling.

import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let model = TranslationModel()
    let popover = NSPopover()
    var panel: PopupPanel!
    var settingsWindow: NSWindow?
    var introWindow: NSWindow?
    var feedbackWindow: NSWindow?
    var sizeObserver: AnyCancellable?
    weak var updateItem: NSMenuItem?

    // capture / popup state (see App+Capture, App+Popup)
    var overlays: [OverlayWindow] = []
    var capturing = false
    var captureStartedAt = Date.distantPast
    var previousApp: NSRunningApplication?
    var tuckedWindows: [NSWindow] = []
    let historyList = HistoryList()
    var historyKeyMonitor: Any?
    var popupFrame: NSRect?
    var reopenedAt: Date?
    var overlayWatchdog: Timer?
    var overlayKeyMonitor: Any?
    var overlayObservers: [NSObjectProtocol] = []
    var anchoredBelow = true
    var shownAt = Date.distantPast
    var popupKeyMonitor: Any?
    var lastAnchor: NSRect?
    /// Set when "Download" in the popup opened the languages window: translate again once it's done.
    var retryAfterDownload: (anchor: NSRect, ids: [String])?

    // shortcuts state (see App+Shortcuts)
    var hotKey: EventHotKeyRef?
    var hotKeyHandlerInstalled = false
    var tapMonitors: [Any] = []
    var tapStartedAt: Date?
    var tapInterrupted = false
    var askedForAccessibility = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard becomeSingleInstance() else { return }
        Appearance.apply()
        installEditMenu()
        setUpStatusItem()
        setUpPopupPanel()
        setUpLanguages()
        NSLog("Lensy: launched \(Updater.currentVersion)")
        if Self.e2e { return }               // end-to-end test copy: no global keys, prompts, windows or update checks
        registerHotKey()
        installQuickScanTap()
        Permissions.requestScreen()
        Updater.shared.isIdle = { [weak self] in
            guard let self else { return true }
            return !self.capturing && !self.panel.isVisible && !self.popover.isShown && !(self.settingsWindow?.isVisible ?? false) && !(self.introWindow?.isVisible ?? false) && !(self.feedbackWindow?.isVisible ?? false)
        }
        Updater.shared.onChange = { [weak self] in self?.showUpdateState() }
        Updater.shared.start()
        NotificationCenter.default.addObserver(forName: IntroView.open, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openIntro() }
        }
        NotificationCenter.default.addObserver(forName: FeedbackView.open, object: nil, queue: .main) { [weak self] note in
            let message = note.object as? String ?? ""
            MainActor.assumeIsolated { self?.showFeedback(message: message) }
        }
        CrashReports.shared.check()
        if let window = AppLanguage.takeReopen() {         // just restarted to switch the interface language
            reopenedAt = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { window == "intro" ? self.openIntro() : self.openSettings() }
        } else if !defaults.bool(forKey: "onboarded") {
            defaults.set(true, forKey: "onboarded")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.openIntro() }      // languages + permission, first run only
        } else if !CGPreflightScreenCaptureAccess() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.openSettings() }   // show what's missing
        } else {
            Task {                                    // the language scans translate into isn't there: nothing would work
                await LanguageDownloads.shared.refresh()
                if LanguageHint.current(target: model.target).state == .missing { openIntro() }
            }
        }
    }

    private func setUpLanguages() {
        let packs = LanguageDownloads.shared
        Task { await packs.refresh() }
        model.onDownload = { [weak self] ids in
            guard let self else { return }
            hidePopup()
            openIntro(download: ids, retry: true)
        }
        packs.onIdle = { [weak self] in
            guard let self, let retry = retryAfterDownload, retry.ids.allSatisfy(packs.isReady) else { return }
            retryAfterDownload = nil
            introWindow?.close()
            model.translate()
            showPopup(below: retry.anchor)
        }
    }

    /// Set by scripts/e2e.sh, which runs a renamed copy next to the real app.
    static let e2e = ProcessInfo.processInfo.environment["LENSY_E2E"] == "1"

    /// Opening Lensy again (Finder, Spotlight) shows Settings — the way back when the menu bar is crowded.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return false
    }

    /// If Lensy is already running, ask that copy to show Settings and quit this one.
    private func becomeSingleInstance() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return true }
        let center = DistributedNotificationCenter.default()
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0 != .current }
        if !others.isEmpty {
            center.postNotificationName(.init(id + ".open"), object: nil, deliverImmediately: true)
            exit(0)
        }
        center.addObserver(forName: .init(id + ".open"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if Self.e2e { NSLog("Lensy: asked to open"); return }
                // a second launch racing the language-switch restart (launchd keep-alive) — the right window is already coming
                if let reopened = self?.reopenedAt, Date().timeIntervalSince(reopened) < 5 { return }
                self?.openSettings()
            }
        }
        return true
    }

    // MARK: - Menu bar item

    private func setUpStatusItem() {
        statusItem.button?.image = MenuBarIcon.current.image
        NotificationCenter.default.addObserver(forName: MenuBarIcon.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.statusItem.button?.image = MenuBarIcon.current.image }
        }
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        popover.behavior = .transient
        popover.animates = true
        historyList.open = { [weak self] scan in self?.reopen(scan) }
        let history = NSHostingController(rootView: HistoryView(list: historyList,
            scan: { [weak self] in self?.popover.performClose(nil); self?.capture() }))
        history.sizingOptions = [.preferredContentSize]
        popover.contentViewController = history
        NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let monitor = self.historyKeyMonitor else { return }
                NSEvent.removeMonitor(monitor)
                self.historyKeyMonitor = nil
            }
        }
    }

    /// Left click: history popover. Right click: a small menu.
    @objc func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showStatusMenu(); return }
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        hidePopup()
        // size the popover before showing it, so it attaches right under the icon
        if let view = popover.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            popover.contentSize = view.fittingSize
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        installHistoryKeys()
    }

    /// ↑ ↓ ↩ ⌘⌫ ⌘C ⌘P ⌘Z in the history — seen before the search field, so the arrows walk the list.
    private func installHistoryKeys() {
        if let monitor = historyKeyMonitor { NSEvent.removeMonitor(monitor) }
        historyKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = Int(event.keyCode), mods = event.modifierFlags
            let handled: Bool = MainActor.assumeIsolated {
                guard let self, self.popover.isShown, event.window == self.popover.contentViewController?.view.window else { return false }
                return self.historyList.handleKey(code, modifiers: mods)
            }
            return handled ? nil : event
        }
    }

    private func showStatusMenu() {
        let menu = makeStatusMenu()
        Updater.shared.refreshIfStale()   // the line updates in place while the menu is open
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
        updateItem = nil
    }

    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item(String(localized: "Scan & Translate"), "text.viewfinder", #selector(capture)))
        menu.addItem(item(String(localized: "Clear History"), "trash", #selector(clearHistory)))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Settings…"), "gearshape", #selector(openSettings), key: ","))
        menu.addItem(item(String(localized: "Send Feedback…"), "envelope", #selector(openFeedback)))
        let update = item("", "", #selector(checkForUpdates))
        updateItem = update
        showUpdateState()
        menu.addItem(update)
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Quit Lensy"), "power", #selector(NSApplication.terminate(_:)), key: "q"))
        return menu
    }

    private func item(_ title: String, _ symbol: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.showsImage()
        return item
    }

    /// "Lensy Is Up to Date · 1.2.1 is the latest version", "Update to Lensy 1.3…", "Checking…".
    func showUpdateState() {
        guard let updateItem else { return }
        let line = Updater.menuLine(Updater.shared.state, version: Updater.currentVersion, enabled: Updater.enabled)
        updateItem.title = line.title
        updateItem.subtitle = line.subtitle
        updateItem.isEnabled = line.enabled
        let config = line.highlighted ? NSImage.SymbolConfiguration(paletteColors: [.white, .controlAccentColor]) : nil
        updateItem.image = NSImage(systemSymbolName: line.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config ?? .init())
        updateItem.showsImage()
    }

    @objc func clearHistory() { History.shared.clear() }
    @objc func checkForUpdates() { Updater.shared.menuAction() }

    // MARK: - Settings

    @objc func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView())
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "Lensy"
            window.titleVisibility = .hidden
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.isMovableByWindowBackground = true
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func openFeedback() { showFeedback(message: "") }

    func showFeedback(message: String) {
        popover.performClose(nil)
        if !message.isEmpty { feedbackWindow?.close(); feedbackWindow = nil }
        if feedbackWindow == nil {
            let host = NSHostingController(rootView: FeedbackView(prefill: message) { [weak self] in self?.closeFeedback() })
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = String(localized: "Send Feedback")
            window.titleVisibility = .hidden
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.isMovableByWindowBackground = true
            window.center()
            feedbackWindow = window
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.feedbackWindow = nil }   // a fresh form next time
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        feedbackWindow?.makeKeyAndOrderFront(nil)
    }

    private func closeFeedback() { feedbackWindow?.close() }

    /// Pick languages and download them for offline use — first run, "Download languages…" in Settings, the menu,
    /// D on the selection overlay, or "Download" in the popup (`download`: start these right away).
    func openIntro(download ids: [String] = [], retry: Bool = false) {
        popover.performClose(nil)
        retryAfterDownload = retry ? lastAnchor.map { ($0, ids) } : nil
        if introWindow == nil {
            let host = NSHostingController(rootView: IntroView(downloads: .shared) { [weak self] in
                self?.retryAfterDownload = nil
                self?.introWindow?.close()
            })
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = String(localized: "Welcome to Lensy")
            window.titleVisibility = .hidden
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.isMovableByWindowBackground = true
            window.center()
            introWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        introWindow?.makeKeyAndOrderFront(nil)
        if !ids.isEmpty { Task { await LanguageDownloads.shared.ensure(ids) } }
    }
}
