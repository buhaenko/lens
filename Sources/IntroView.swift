// First-run intro: pick the languages to read in and download them for offline use, with progress per language.
// Apple's Translation framework doesn't report download percentages, so a bar eases forward while a download
// runs and fills when macOS reports the language as installed.

import AppKit
import Combine
import SwiftUI
import Translation

/// The one place that knows which languages are downloaded. Shared by the intro window, Settings, the menu,
/// the selection overlay and the popup, so the status shown everywhere is the same.
@MainActor final class LanguageDownloads: ObservableObject {
    enum Status: Equatable {
        case checking, ready, needed, unsupported, failed
        case downloading(Double)
    }

    static let shared = LanguageDownloads()

    @Published var selected: [String]
    /// Not in the Tab list, but needed right now — e.g. the language of a scanned text that isn't downloaded yet.
    @Published var extra: [String] = []
    @Published var status: [String: Status] = [:]
    @Published var config: TranslationSession.Configuration?
    private var queue: [String] = []
    @Published private(set) var current: String?
    private var ticker: Timer?
    /// Called when every queued download has finished (or failed).
    var onIdle: () -> Void = {}

    init(selected: [String] = langs.map(\.id)) { self.selected = selected }

    /// Every row the intro shows: the chosen languages, then the extra ones.
    var rows: [String] { selected + extra.filter { !selected.contains($0) } }
    var needed: [String] { rows.filter { status[$0] == .needed || status[$0] == .failed } }
    var isDownloading: Bool { current != nil }
    func isReady(_ id: String) -> Bool { status[id] == .ready }

    /// Settings changed the list: follow it.
    func sync() {
        selected = langs.map(\.id)
        extra.removeAll { selected.contains($0) }
        Task { await refresh() }
    }

    func add(_ id: String) {
        guard !selected.contains(id) else { return }
        selected.append(id)
        extra.removeAll { $0 == id }
        save()
        Task { await refresh() }
    }

    func remove(_ id: String) {
        guard rows.count > 1, current != id else { return }
        if selected.contains(id) {
            guard selected.count > 1 else { return }
            selected.removeAll { $0 == id }
            save()
        }
        extra.removeAll { $0 == id }
        queue.removeAll { $0 == id }
    }

    private func save() { defaults.set(selected, forKey: "languages") }

    /// Make sure these are downloaded: shows them in the intro and starts whatever is missing.
    func ensure(_ ids: [String]) async {
        for id in ids where !rows.contains(id) { extra.append(id) }
        await refresh()
        for id in ids where status[id] == .needed || status[id] == .failed { download(id) }
        if current == nil && queue.isEmpty { onIdle() }
    }

    func refresh() async {
        for id in rows where current != id {
            if status[id] == nil { status[id] = .checking }
            let now = await check(id)
            if current != id { status[id] = now }
        }
    }

    /// A pack is checked (and downloaded) as a pair with English — or, for English itself, with another chosen language.
    func pairSource(for id: String) -> String? {
        Self.base(id) == "en" ? rows.first { Self.base($0) != "en" } : "en"
    }

    private func check(_ id: String) async -> Status {
        guard let source = pairSource(for: id) else { return .ready }
        return Self.status(await Self.availability(source, id))
    }

    static func status(_ s: LanguageAvailability.Status) -> Status {
        switch s {
        case .installed: .ready
        case .supported: .needed
        case .unsupported: .unsupported
        @unknown default: .needed
        }
    }

    static func availability(_ from: String, _ to: String) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: Locale.Language(identifier: from), to: Locale.Language(identifier: to))
    }

    /// Can this text be translated offline right now? Checked before every translation, so the popup never
    /// waits on a language that isn't there (macOS can't show its download prompt in the popup).
    static func pairStatus(source: String?, target: String, text: String) async -> LanguageAvailability.Status {
        if let source { return await availability(source, target) }
        do { return try await LanguageAvailability().status(for: text, to: Locale.Language(identifier: target)) }
        catch { return .installed }       // the language can't be told — let the translation try, the timeout covers it
    }

    /// Which of these two languages still have to be downloaded (each checked against English).
    static func missing(source: String?, target: String) async -> [String] {
        let ids = [source, target].compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        var out: [String] = []
        for id in ids {
            let partner = base(id) == "en" ? ids.first { base($0) != "en" } : "en"
            guard let partner else { continue }
            if await availability(partner, id) != .installed { out.append(id) }
        }
        return out.isEmpty ? ids.filter { base($0) != "en" } : out
    }

    func downloadAll() {
        queue = needed.filter { $0 != current }
        next()
    }

    func download(_ id: String) {
        if !queue.contains(id) && current != id { queue.append(id) }
        next()
    }

    private func next() {
        guard current == nil else { return }
        while let id = queue.first {
            queue.removeFirst()
            guard let source = pairSource(for: id) else { continue }
            current = id
            status[id] = .downloading(0.03)
            startTicker()
            config = .init(source: Locale.Language(identifier: source), target: Locale.Language(identifier: id))
            return
        }
    }

    /// Runs inside `.translationTask`: macOS asks once, then downloads.
    func run(_ session: TranslationSession) async {
        guard let id = current else { return }
        var ok = true
        do { try await session.prepareTranslation() } catch { ok = false }
        let after = await check(id)
        ticker?.invalidate()
        if after == .ready {
            withAnimation(.easeOut(duration: 0.35)) { status[id] = .downloading(1) }
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.easeOut(duration: 0.2)) { status[id] = .ready }
        } else {
            status[id] = ok ? .needed : .failed
        }
        current = nil
        config = nil
        await refresh()          // a pair can bring in more than one language (English, for one)
        next()
        if current == nil { onIdle() }
    }

    /// Eases towards 90 % while the download runs; the last stretch happens when it's actually installed.
    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let id = self.current, case .downloading(let p) = self.status[id] else { return }
                self.status[id] = .downloading(p + (0.9 - p) * 0.012)
            }
        }
    }

    static func base(_ id: String) -> String { Locale.Language(identifier: id).languageCode?.identifier ?? id }
}

struct IntroView: View {
    static let open = Notification.Name("LensOpenIntro")
    @ObservedObject var downloads: LanguageDownloads
    var done: () -> Void = {}
    @State private var available: [String] = []
    @State private var hasScreenRecording = Permissions.screenRecording
    let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                Text("Welcome to Lensy").font(.system(size: 20, weight: .semibold))
                Text("Choose the languages you want to read in.\nThey download once — then everything works offline.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)

            VStack(spacing: 0) {
                ForEach(Array(downloads.rows.enumerated()), id: \.element) { index, id in
                    if index > 0 { Divider().padding(.leading, 14) }
                    LanguageDownloadRow(lang: makeLang(id), status: downloads.status[id] ?? .checking,
                                        canRemove: (downloads.selected.count > 1 || !downloads.selected.contains(id)) && downloads.current != id,
                                        download: { downloads.download(id) }, remove: { downloads.remove(id) })
                }
                Divider()
                Menu {
                    ForEach(available.filter { !downloads.rows.contains($0) }, id: \.self) { id in
                        Button(makeLang(id).name) { downloads.add(id) }
                    }
                } label: {
                    Label("Add language", systemImage: "plus").font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).frame(height: 36)
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))

            if !hasScreenRecording {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.dashed").font(.system(size: 15)).foregroundStyle(.orange).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Screen Recording").font(.system(size: 12.5, weight: .medium))
                        Text("Lets Lensy read the area you select. Nothing is recorded or saved.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Allow…") { Permissions.guide(to: .screenRecording) }.controlSize(.small)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.08)))
            }

            HStack {
                Text(footnote).font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                if !downloads.needed.isEmpty || downloads.isDownloading {
                    Button(downloads.isDownloading ? "Downloading…" : "Download \(downloads.needed.count == 1 ? "1 language" : "\(downloads.needed.count) languages")") {
                        downloads.downloadAll()
                    }
                    .disabled(downloads.isDownloading)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
                if downloads.needed.isEmpty && !downloads.isDownloading {
                    Button("Start using Lensy", action: done).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button("Later", action: done).keyboardShortcut(.cancelAction)
                }
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .translationTask(downloads.config) { session in await downloads.run(session) }
        .task {
            await downloads.refresh()
            let languages = await LanguageAvailability().supportedLanguages
            available = Array(Set(languages.map(\.minimalIdentifier))).sorted { makeLang($0).name.localizedCompare(makeLang($1).name) == .orderedAscending }
        }
        .onReceive(tick) { _ in hasScreenRecording = Permissions.screenRecording }
    }

    private var footnote: String {
        if downloads.isDownloading { return "Keep this window open until it’s done" }
        return downloads.needed.isEmpty ? "Tab in the popup switches between these" : "Downloaded from Apple, only once"
    }
}

private struct LanguageDownloadRow: View {
    let lang: Lang
    let status: LanguageDownloads.Status
    let canRemove: Bool
    var download: () -> Void
    var remove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Text(lang.code)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.07)))
            Text(lang.name).font(.system(size: 13))
            Spacer(minLength: 12)
            trailing
            if canRemove {
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).opacity(hover ? 1 : 0).help("Remove")
            }
        }
        .padding(.horizontal, 14).frame(height: 44)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    @ViewBuilder private var trailing: some View {
        switch status {
        case .checking:
            ProgressView().controlSize(.mini)
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.green).labelStyle(.titleAndIcon)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        case .needed:
            Button(action: download) { Label("Download", systemImage: "arrow.down.circle").font(.system(size: 11.5)) }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
        case .failed:
            Button(action: download) { Label("Try again", systemImage: "arrow.clockwise").font(.system(size: 11.5)) }
                .buttonStyle(.plain).foregroundStyle(.orange)
        case .unsupported:
            Text("Not available").font(.system(size: 11.5)).foregroundStyle(.tertiary)
        case .downloading(let progress):
            ProgressView(value: progress).progressViewStyle(.linear).frame(width: 120).tint(.accentColor)
                .animation(.linear(duration: 0.12), value: progress)
        }
    }
}
