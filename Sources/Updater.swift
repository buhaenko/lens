// Updates: checks the latest GitHub release once a day, installs it when Lensy is idle and restarts.
// Every update archive is signed (Ed25519, scripts/sign-update.swift); anything that doesn't verify is ignored.

import AppKit
import CryptoKit

@MainActor final class Updater {
    static let shared = Updater()

    nonisolated static let publicKey = "gxyL+hDC5CLF7DexlMs406IZiXX7iGjWN+pwrKrrn0E="
    nonisolated static let feed = URL(string: "https://api.github.com/repos/buhaenko/lensy/releases/latest")!
    nonisolated static let downloadPage = URL(string: "https://github.com/buhaenko/lensy/releases/latest")!
    nonisolated static let archiveName = "Lensy.zip"

    /// Lensy isn't in the middle of something — safe to restart.
    var isIdle: () -> Bool = { true }
    /// Called whenever `state` changes (the menu item redraws, even while the menu is open).
    var onChange: (() -> Void)?

    enum State: Equatable {
        case unknown, checking, upToDate, failed
        case available(String), installing(String)
    }
    private(set) var state: State = .unknown { didSet { if state != oldValue { onChange?() } } }
    private var found: Release?

    nonisolated static var automatic: Bool { defaults.object(forKey: "autoUpdate") as? Bool ?? true }
    nonisolated static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    /// Development builds never update themselves.
    nonisolated static var enabled: Bool { isRelease(currentVersion) }

    struct Release: Equatable, Sendable {
        var version: String
        var archive: URL
        var signature: URL
    }

    enum Failure: LocalizedError {
        case download, badSignature, badArchive, notWritable
        var errorDescription: String? {
            switch self {
            case .download: String(localized: "Couldn’t download the update. Check your connection and try again.")
            case .badSignature: String(localized: "The downloaded update isn’t signed by Lensy, so it wasn’t installed.")
            case .badArchive: String(localized: "The downloaded update looks broken, so it wasn’t installed.")
            case .notWritable: String(localized: "Lensy can’t replace itself in this folder. Download the new version and drag it to Applications.")
            }
        }
    }

    // MARK: - Schedule

    /// Shortly after launch, then once a day; installs on its own when Lensy is idle.
    func start() {
        guard Self.enabled else { return }
        Task {
            try? await Task.sleep(for: .seconds(20))
            while true {
                let last = defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
                if Self.automatic && Date().timeIntervalSince(last) > 23 * 3600, let release = await refresh() {
                    await install(release, interactive: false)
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// The menu just opened: make sure the update line isn't stale (at most one request an hour).
    func refreshIfStale() {
        guard Self.enabled else { return }
        let last = defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        if state == .unknown || state == .failed || Date().timeIntervalSince(last) > 3600 { Task { await refresh() } }
    }

    /// Asks GitHub for the latest release. Returns it only when it's newer than this copy.
    @discardableResult func refresh(feed: URL = Updater.feed) async -> Release? {
        switch state { case .checking, .installing: return nil; default: break }
        state = .checking
        defaults.set(Date(), forKey: "lastUpdateCheck")
        guard let (data, _) = try? await URLSession.shared.data(from: feed) else { state = .failed; return nil }
        if let release = Self.parse(data), Self.isNewer(release.version, than: Self.currentVersion) {
            found = release
            state = .available(release.version)
            return release
        }
        found = nil
        state = .upToDate
        return nil
    }

    /// The update line in the menu was clicked.
    func menuAction() {
        Task {
            if case .available = state, let found { await install(found, interactive: true); return }
            if let release = await refresh() { await install(release, interactive: true); return }
            if state == .failed { tell(String(localized: "Couldn’t check for updates"), String(localized: "Check your connection and try again.")) }
        }
    }

    /// interactive: asks first and explains failures. Automatic: silent, waits until Lensy is idle.
    func install(_ release: Release, interactive: Bool) async {
        let current = Self.currentVersion
        if interactive && !ask(String(localized: "Lensy \(release.version) is available"), String(localized: "You have \(current). Lensy restarts in a second — your history and settings stay."), ok: String(localized: "Install & Restart")) { return }
        state = .installing(release.version)
        do {
            let app = Bundle.main.bundleURL
            guard FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else { throw Failure.notWritable }
            let staged = try await Self.prepare(release, replacing: app)
            while !interactive && !isIdle() { try await Task.sleep(for: .seconds(60)) }
            try Self.install(staged, over: app)
            NSLog("Lensy: updated to \(release.version), restarting")
            relaunch(app)
        } catch {
            NSLog("Lensy: update failed — \(error.localizedDescription)")
            state = .available(release.version)
            guard interactive else { return }
            if case Failure.notWritable = error {
                if ask(String(localized: "Update Lensy manually"), error.localizedDescription, ok: String(localized: "Download")) { NSWorkspace.shared.open(Self.downloadPage) }
            } else {
                tell(String(localized: "Lensy couldn’t update"), (error as? Failure)?.errorDescription ?? Failure.download.errorDescription!)
            }
        }
    }

    // MARK: - Menu line

    struct MenuLine: Equatable {
        var title: String, subtitle: String, symbol: String, enabled: Bool, highlighted = false
    }

    /// What the update item in the menu says for each state.
    nonisolated static func menuLine(_ state: State, version: String, enabled: Bool = true) -> MenuLine {
        guard enabled else { return MenuLine(title: String(localized: "Development Build"), subtitle: String(localized: "Updates are off"), symbol: "hammer", enabled: false) }
        switch state {
        case .unknown: return MenuLine(title: String(localized: "Check for Updates…"), subtitle: "Lensy \(version)", symbol: "arrow.triangle.2.circlepath", enabled: true)
        case .checking: return MenuLine(title: String(localized: "Checking for Updates…"), subtitle: "Lensy \(version)", symbol: "arrow.triangle.2.circlepath", enabled: false)
        case .upToDate: return MenuLine(title: String(localized: "Lensy Is Up to Date"), subtitle: String(localized: "\(version) is the latest version"), symbol: "checkmark.circle", enabled: true)
        case .failed: return MenuLine(title: String(localized: "Check for Updates…"), subtitle: String(localized: "Couldn’t connect — try again"), symbol: "exclamationmark.arrow.triangle.2.circlepath", enabled: true)
        case .available(let new): return MenuLine(title: String(localized: "Update to Lensy \(new)…"), subtitle: String(localized: "You have \(version)"), symbol: "arrow.down.circle.fill", enabled: true, highlighted: true)
        case .installing(let new): return MenuLine(title: String(localized: "Installing Lensy \(new)…"), subtitle: String(localized: "Lensy restarts when it’s done"), symbol: "arrow.down.circle", enabled: false)
        }
    }

    // MARK: - Steps (static so the tests can run them on their own)

    /// GitHub's "latest release" JSON → version and the two files we need.
    nonisolated static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, let assets = json["assets"] as? [[String: Any]] else { return nil }
        func asset(_ name: String) -> URL? {
            (assets.first { $0["name"] as? String == name }?["browser_download_url"] as? String).flatMap(URL.init(string:))
        }
        guard let archive = asset(archiveName), let signature = asset(archiveName + ".sig") else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return isRelease(version) ? Release(version: version, archive: archive, signature: signature) : nil
    }

    /// "1.2.10" > "1.2.9", "1.3" > "1.2.9"; anything that isn't plain numbers never counts as newer.
    nonisolated static func isNewer(_ version: String, than current: String) -> Bool {
        guard isRelease(version) else { return false }
        let a = version.split(separator: ".").compactMap { Int($0) }
        let b = isRelease(current) ? current.split(separator: ".").compactMap { Int($0) } : []
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    nonisolated static func isRelease(_ version: String) -> Bool {
        version.range(of: #"^\d+(\.\d+){0,3}$"#, options: .regularExpression) != nil
    }

    nonisolated static func verify(_ data: Data, signature: String, publicKey: String = Updater.publicKey) -> Bool {
        guard let raw = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              let sig = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return key.isValidSignature(sig, for: data)
    }

    /// Download, verify the signature, unpack next to the app (same volume) and check the bundle inside.
    nonisolated static func prepare(_ release: Release, replacing app: URL, publicKey: String = Updater.publicKey,
                                    bundleID: String? = Bundle.main.bundleIdentifier, current: String = Updater.currentVersion) async throws -> URL {
        guard let (zip, _) = try? await URLSession.shared.data(from: release.archive),
              let (sig, _) = try? await URLSession.shared.data(from: release.signature) else { throw Failure.download }
        guard verify(zip, signature: String(decoding: sig, as: UTF8.self), publicKey: publicKey) else { throw Failure.badSignature }

        let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        let archive = work.appendingPathComponent(archiveName)
        try zip.write(to: archive)
        guard run("/usr/bin/ditto", "-x", "-k", archive.path, work.path) else { throw Failure.badArchive }
        let staged = work.appendingPathComponent(app.lastPathComponent)
        guard let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleID,
              info["CFBundleShortVersionString"] as? String == release.version,
              isNewer(release.version, than: current),
              run("/usr/bin/codesign", "--verify", "--strict", staged.path) else { throw Failure.badArchive }
        return staged
    }

    /// Swaps the new bundle in place of the running one. Same signing identity → permissions carry over.
    nonisolated static func install(_ staged: URL, over app: URL) throws {
        _ = try FileManager.default.replaceItemAt(app, withItemAt: staged)
        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
    }

    /// Opens the new copy as soon as this one has quit.
    private func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try? shell.run()
        NSApp.terminate(nil)
    }

    nonisolated private static func run(_ tool: String, _ arguments: String...) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: - Alerts

    private func tell(_ title: String, _ text: String) { _ = ask(title, text, ok: String(localized: "OK"), cancel: nil) }

    private func ask(_ title: String, _ text: String, ok: String, cancel: String? = String(localized: "Later")) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: ok)
        if let cancel { alert.addButton(withTitle: cancel) }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
