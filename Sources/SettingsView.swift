// Settings window: translation languages first, then shortcuts, popup and general options.

import AppKit
import SwiftUI
import Combine
import Translation
import ServiceManagement
import Carbon.HIToolbox

struct SettingsView: View {
    @ObservedObject var packs = LanguageDownloads.shared
    @State private var selected: [String] = langs.map(\.id)
    @State private var available: [String] = []
    @State private var tapKey = TapKey.current
    @State private var shortcutLabel = ScanHotKey.label
    @State private var recording = false
    @State private var recorderMonitor: Any?
    @State private var appearance = Appearance.current
    @AppStorage("autoCopy") private var autoCopy = false
    @AppStorage("showOriginal") private var showOriginal = true
    @AppStorage("saveHistory") private var saveHistory = true
    @AppStorage("historyLimit") private var historyLimit = 100
    @AppStorage("autoUpdate") private var autoUpdate = true
    @State private var showFilters = false
    @State private var activeFilters = HistoryFilter.current.activeCount
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var menuBarIcon = MenuBarIcon.current
    @State private var hasAccessibility = Permissions.accessibility
    @State private var hasScreenRecording = Permissions.screenRecording
    let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
                Text("Lensy").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(shortcutHint()).font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }

            group("Translate into", footer: "Tab in the popup cycles through these, in this order. Drag to reorder.") {
                List {
                    ForEach(Array(selected.enumerated()), id: \.element) { index, id in
                        VStack(spacing: 0) {
                            if index > 0 { Divider().padding(.leading, 12) }
                            LanguageRow(lang: makeLang(id), status: packs.status[id], canRemove: selected.count > 1) {
                                selected.removeAll { $0 == id }
                                save()
                            }
                        }
                        .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
                    }
                    .onMove { selected.move(fromOffsets: $0, toOffset: $1); save() }
                }
                .listStyle(.plain).scrollContentBackground(.hidden).scrollDisabled(true)
                .frame(height: CGFloat(selected.count) * 36 + CGFloat(max(selected.count - 1, 0)))
                Divider()
                Menu {
                    ForEach(available.filter { !selected.contains($0) }, id: \.self) { id in
                        Button(makeLang(id).name) { selected.append(id); save() }
                    }
                } label: {
                    Label("Add language", systemImage: "plus").font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: 34)
                Divider()
                Button { NotificationCenter.default.post(name: IntroView.open, object: nil) } label: {
                    Label("Download for offline use…", systemImage: "arrow.down.circle").font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.horizontal, 12).frame(height: 34)
            }

            group("Shortcuts") {
                row("Scan & translate") {
                    Text(recording ? "Type a shortcut…" : shortcutLabel)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(recording ? Color.accentColor : .secondary)
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(recording ? 0.12 : 0.07)))
                        .contentShape(Rectangle())
                        .onTapGesture { recording ? stopRecording() : startRecording() }
                        .help("Click, then press the new shortcut · Esc cancels")
                }
                Divider().padding(.leading, 12)
                row("Quick scan — tap alone") {
                    Picker("", selection: $tapKey) { ForEach(TapKey.allCases) { Text($0.label).tag($0) } }
                        .labelsHidden().fixedSize()
                        .onChange(of: tapKey) { _, key in defaults.set(key.rawValue, forKey: "tapKey") }
                }
            }

            group("Popup & history") {
                toggleRow("Show the original text", $showOriginal)
                Divider().padding(.leading, 12)
                toggleRow("Copy the translation automatically", $autoCopy)
                Divider().padding(.leading, 12)
                row("Keep history") {
                    Picker("", selection: Binding(get: { saveHistory ? historyLimit : 0 },
                                                  set: { saveHistory = $0 > 0; if $0 > 0 { historyLimit = $0 } })) {
                        Text("Off").tag(0)
                        ForEach([25, 100, 500], id: \.self) { Text("\($0) scans").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                if saveHistory {
                    Divider().padding(.leading, 12)
                    row("History filters") {
                        Button { showFilters.toggle() } label: {
                            HStack(spacing: 4) {
                                Text(activeFilters == 0 ? "None" : "\(activeFilters) on")
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            }
                            .font(.system(size: 12)).foregroundStyle(.secondary).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showFilters, arrowEdge: .trailing) {
                            FilterView { activeFilters = HistoryFilter.current.activeCount }
                        }
                    }
                }
            }

            group("General") {
                row("Appearance") {
                    Picker("", selection: $appearance) {
                        ForEach(Appearance.allCases) { choice in
                            Label(choice.title, systemImage: choice.symbol).tag(choice)
                        }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                    .onChange(of: appearance) { _, choice in Appearance.apply(choice) }
                }
                Divider().padding(.leading, 12)
                row("Menu bar icon") {
                    Picker("", selection: $menuBarIcon) {
                        ForEach(MenuBarIcon.allCases) { icon in
                            Image(nsImage: icon.image).help(icon.title).tag(icon)
                        }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                    .onChange(of: menuBarIcon) { _, icon in
                        defaults.set(icon.rawValue, forKey: "menuBarIcon")
                        NotificationCenter.default.post(name: MenuBarIcon.changed, object: nil)
                    }
                }
                Divider().padding(.leading, 12)
                row("Launch at login") {
                    Toggle("", isOn: $launchAtLogin).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .onChange(of: launchAtLogin) { _, on in
                            do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                            catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                        }
                }
                Divider().padding(.leading, 12)
                toggleRow("Update automatically", $autoUpdate)
                if !hasScreenRecording {
                    Divider().padding(.leading, 12)
                    permissionRow("Screen Recording is off", pane: .screenRecording)
                }
                if !hasAccessibility && tapKey != .off {
                    Divider().padding(.leading, 12)
                    permissionRow("Accessibility is off — needed for quick scan", pane: .accessibility)
                }
            }

            Text("Recognition and translation run on your Mac · v\(version)")
                .font(.system(size: 11)).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 16)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            await packs.refresh()
            let languages = await LanguageAvailability().supportedLanguages
            available = Array(Set(languages.map(\.minimalIdentifier))).sorted { makeLang($0).name.localizedCompare(makeLang($1).name) == .orderedAscending }
        }
        .onReceive(tick) { _ in
            hasAccessibility = Permissions.accessibility
            hasScreenRecording = Permissions.screenRecording
        }
    }

    private func save() {
        defaults.set(selected, forKey: "languages")
        packs.sync()
    }

    // MARK: - Building blocks

    private func group<Content: View>(_ title: String, footer: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
            if let footer {
                Text(footer).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.leading, 4)
            }
        }
    }

    private func row<Trailing: View>(_ title: String, @ViewBuilder _ trailing: () -> Trailing) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12).frame(height: 38)
    }

    private func toggleRow(_ title: String, _ value: Binding<Bool>) -> some View {
        row(title) { Toggle("", isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small) }
    }

    private func permissionRow(_ title: String, pane: Permissions.Pane) -> some View {
        row(title) { Button("Allow…") { Permissions.guide(to: pane) }.controlSize(.small) }
            .foregroundStyle(.orange)
    }

    // MARK: - Shortcut recorder

    private func startRecording() {
        recording = true
        recorderMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape { stopRecording(); return nil }
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard !flags.isEmpty, let key = event.charactersIgnoringModifiers?.uppercased(), !key.isEmpty else { return nil }
            var mods = 0, label = ""
            if flags.contains(.control) { mods |= controlKey; label += "⌃" }
            if flags.contains(.option) { mods |= optionKey; label += "⌥" }
            if flags.contains(.shift) { mods |= shiftKey; label += "⇧" }
            if flags.contains(.command) { mods |= cmdKey; label += "⌘" }
            defaults.set(Int(event.keyCode), forKey: "hotKeyCode")
            defaults.set(mods, forKey: "hotKeyMods")
            defaults.set(label + key, forKey: "hotKeyLabel")
            shortcutLabel = label + key
            NotificationCenter.default.post(name: ScanHotKey.changed, object: nil)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor = recorderMonitor { NSEvent.removeMonitor(monitor) }
        recorderMonitor = nil
    }
}

/// One target language: code, native name, remove on hover.
private struct LanguageRow: View {
    let lang: Lang
    let status: LanguageDownloads.Status?
    let canRemove: Bool
    var remove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Text(lang.code)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            Text(lang.name).font(.system(size: 13))
            Spacer()
            switch status {
            case .ready:
                Label("Downloaded", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.green).help("Works offline")
            case .needed, .failed:
                Text("Not downloaded").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.orange)
                Button { NotificationCenter.default.post(name: IntroView.open, object: nil) } label: {
                    Label("Download", systemImage: "arrow.down.circle").font(.system(size: 11.5))
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor).help("Scans won’t translate into it until it’s downloaded")
            case .downloading:
                ProgressView().controlSize(.mini)
                Text("Downloading…").font(.system(size: 11.5)).foregroundStyle(.secondary)
            case .unsupported:
                Text("Not available").font(.system(size: 11)).foregroundStyle(.tertiary)
            case .checking, nil:
                Text("Checking…").font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
            if canRemove {
                Button(action: remove) {
                    Image(systemName: "minus.circle").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain).opacity(hover ? 1 : 0).help("Remove")
            }
        }
        .padding(.horizontal, 12).frame(height: 36)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}
