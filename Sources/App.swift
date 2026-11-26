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
    var overlayWatchdog: Timer?
    var overlayKeyMonitor: Any?
    var overlayObservers: [NSObjectProtocol] = []
    var anchoredBelow = true
    var shownAt = Date.distantPast
    var popupKeyMonitor: Any?

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
        if !defaults.bool(forKey: "onboarded") {
            defaults.set(true, forKey: "onboarded")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.openIntro() }      // languages + permission, first run only
        } else if !CGPreflightScreenCaptureAccess() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.openSettings() }   // show what's missing
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
        let history = NSHostingController(rootView: HistoryView(
            open: { [weak self] scan in self?.reopen(scan) },
            scan: { [weak self] in self?.popover.performClose(nil); self?.capture() }))
        history.sizingOptions = [.preferredContentSize]
        popover.contentViewController = history
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
        menu.addItem(item("Scan & Translate", "text.viewfinder", #selector(capture)))
        menu.addItem(item("Clear History", "trash", #selector(clearHistory)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", "gearshape", #selector(openSettings), key: ","))
        menu.addItem(item("Send Feedback…", "envelope", #selector(openFeedback)))
        let update = item("", "", #selector(checkForUpdates))
        updateItem = update
        showUpdateState()
        menu.addItem(update)
        menu.addItem(.separator())
        menu.addItem(item("Quit Lensy", "power", #selector(NSApplication.terminate(_:)), key: "q"))
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

    @objc func openFeedback() {
        popover.performClose(nil)
        if feedbackWindow == nil {
            let host = NSHostingController(rootView: FeedbackView { [weak self] in self?.closeFeedback() })
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "Send Feedback"
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

    /// Pick languages and download them for offline use — first run, or "Download languages…" in Settings.
    @objc func openIntro() {
        popover.performClose(nil)
        if introWindow == nil {
            let host = NSHostingController(rootView: IntroView(downloads: LanguageDownloads()) { [weak self] in self?.introWindow?.close() })
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "Welcome to Lensy"
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
    }
}
