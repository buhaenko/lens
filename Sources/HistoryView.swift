// Menu bar popover: history of scans and permission hints.

import AppKit
import SwiftUI
import Combine

struct HistoryView: View {
    @ObservedObject var list: HistoryList
    @ObservedObject var history: History
    var scan: () -> Void
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(list: HistoryList, scan: @escaping () -> Void) {
        self.list = list
        self.history = list.history
        self.scan = scan
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Lensy").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: scan) {
                    Label("Scan", systemImage: "text.viewfinder").font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help(String(localized: "\(shortcutHint()) · right-click the icon for Settings"))
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            PermissionBanner()
            CrashBanner()

            if history.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkle").font(.system(size: 24, weight: .light)).foregroundStyle(.tertiary)
                    Text("No scans yet").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Text("\(shortcutHint()), then select text").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity).padding(.top, 28).padding(.bottom, list.undo == nil ? 36 : 12)
                .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.95)))
                if list.undo != nil { footer }
            } else {
                searchField
                ScrollViewReader { proxy in
                    ScrollView {
                        // One list for both sections, so pinning slides a row between them and deleting closes the gap smoothly.
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(entries) { entry in
                                switch entry {
                                case .header(let title, let icon):
                                    sectionTitle(title, systemImage: icon).transition(.opacity)
                                case .scan(let item, let first):
                                    VStack(spacing: 0) {
                                        if !first { Divider().opacity(0.5).padding(.horizontal, 8) }
                                        ScanRow(item: item, selected: list.selected == item.id,
                                                open: { list.open(item) },
                                                togglePin: { list.togglePin(item.id) },
                                                remove: { list.remove(item.id) })
                                    }
                                    .id(item.id)
                                    .transition(rowTransition)
                                case .noMatch:
                                    Text("Nothing matches “\(list.query)”")
                                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                                        .frame(maxWidth: .infinity).padding(.vertical, 28)
                                        .transition(.opacity)
                                }
                            }
                        }
                        .padding(.horizontal, 8).padding(.bottom, 8)
                        .animation(Motion.list, value: list.query)
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: 480)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: list.selected) { _, id in
                        guard let id else { return }
                        withAnimation(Motion.quick) { proxy.scrollTo(id) }
                    }
                }
                footer
            }
        }
        .frame(width: 360)
        .onAppear { list.reset(); searchFocused = true }
    }

    /// The summary and Clear — or, right after a deletion, Undo.
    private var footer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            ZStack {
                if let undo = list.undo {
                    HStack(spacing: 8) {
                        Image(systemName: "trash").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                        Text(undo.text).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        Spacer()
                        Button { list.undoLast() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.uturn.backward").font(.system(size: 9.5, weight: .semibold))
                                Text("Undo")
                                Text("⌘Z").foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.borderless).font(.system(size: 11, weight: .semibold))
                    }
                    .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 6)))
                } else {
                    HStack {
                        Text(summary).font(.system(size: 10)).foregroundStyle(.tertiary)
                            .contentTransition(.numericText()).animation(Motion.list, value: summary)
                        Spacer()
                        Button(clearTitle) { list.clear() }
                            .buttonStyle(.borderless).font(.system(size: 10, weight: .medium))
                            .foregroundStyle(list.confirmingClear ? Color.red : Color.secondary)
                            .contentTransition(.interpolate)
                            .disabled(history.recent.isEmpty)
                    }
                    .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : -6)))
                }
            }
            .frame(height: 16)
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 12)
        }
    }

    private var clearTitle: String {
        if list.confirmingClear {
            let count = history.recent.count
            return count == 1 ? String(localized: "Clear 1 scan?") : String(localized: "Clear \(count) scans?")
        }
        return history.pinned.isEmpty ? String(localized: "Clear") : String(localized: "Clear unpinned")
    }

    /// Deleted rows slide off to the right as the ones below close up; new ones settle in from above.
    private var rowTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
            removal: .opacity.combined(with: .offset(x: 40)).combined(with: .scale(scale: 0.98)))
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
            TextField("Search", text: $list.query)
                .textFieldStyle(.plain).font(.system(size: 12.5))
                .focused($searchFocused)
                .onExitCommand { list.query = "" }
            if !list.query.isEmpty {
                Button { list.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 12).padding(.bottom, 6)
    }

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.tertiary)
            .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 2)
    }

    private enum Entry: Identifiable {
        case header(String, String), scan(Scan, first: Bool), noMatch
        var id: String {
            switch self {
            case .header(let title, _): "header-" + title
            case .scan(let item, _): item.id.uuidString
            case .noMatch: "no-match"
            }
        }
    }

    private var entries: [Entry] {
        let pinned = list.pinned, recent = list.recent
        var list: [Entry] = []
        if !pinned.isEmpty {
            list.append(.header(String(localized: "Pinned"), "pin.fill"))
            list += pinned.enumerated().map { .scan($1, first: $0 == 0) }
            if !recent.isEmpty { list.append(.header(String(localized: "Recent"), "clock")) }
        }
        list += recent.enumerated().map { .scan($1, first: $0 == 0) }
        if pinned.isEmpty && recent.isEmpty { list.append(.noMatch) }
        return list
    }

    private var summary: String {
        let count = history.items.count
        let pins = history.pinned.count
        let scans = count == 1 ? String(localized: "1 scan") : String(localized: "\(count) scans")
        return pins > 0 ? scans + " · " + String(localized: "\(pins) pinned") : scans
    }
}

/// Shows what's missing for the shortcut / capture to work, with a button straight to the right Settings pane.
struct PermissionBanner: View {
    @ObservedObject var packs = LanguageDownloads.shared
    @State private var hasAccessibility = Permissions.accessibility
    @State private var hasScreenRecording = Permissions.screenRecording
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 6) {
            if !hasAccessibility { row("The quick-scan key needs Accessibility", .accessibility) }
            if !hasScreenRecording { row("Scanning needs Screen Recording", .screenRecording) }
            if !missing.isEmpty { languageRow }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, (hasAccessibility && hasScreenRecording && missing.isEmpty) ? 0 : 8)
        .task { await packs.refresh() }
        .onReceive(timer) { _ in hasAccessibility = Permissions.accessibility; hasScreenRecording = Permissions.screenRecording }
    }

    /// Chosen languages that aren't downloaded — scans into them can't be translated yet.
    private var missing: [String] { packs.selected.filter { [.needed, .failed].contains(packs.status[$0]) } }

    private var missingText: String {
        let names = ListFormatter.localizedString(byJoining: missing.map { makeLang($0).name })
        return missing.count == 1 ? String(localized: "\(names) isn’t downloaded yet") : String(localized: "\(names) aren’t downloaded yet")
    }

    private var languageRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.orange)
            Text(missingText)
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            Button("Download") { NotificationCenter.default.post(name: IntroView.open, object: nil) }
            .buttonStyle(.borderless).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.1)))
    }

    func row(_ text: LocalizedStringKey, _ pane: Permissions.Pane) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button("Open") { Permissions.guide(to: pane) }
            .buttonStyle(.borderless).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.1)))
    }
}

/// One scan: the translation leads, the original follows quietly, languages and time stay out of the way.
struct ScanRow: View {
    let item: Scan
    var selected = false
    var open: () -> Void
    var togglePin: () -> Void
    var remove: () -> Void
    @State private var hover = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(languages)
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                    Text(time).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    if item.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary).rotationEffect(.degrees(40))
                    }
                }
                Text(item.translated)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineSpacing(2)
                    .lineLimit(3)
                    .foregroundStyle(.primary)
                Text(item.original)
                    .font(.system(size: 12))
                    .lineSpacing(1.5)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .topTrailing) {
            // actions sit on the (short) language/time line, so they never cost vertical space
            HStack(spacing: 4) {
                iconButton(copied ? "checkmark" : "doc.on.doc", copied ? "Copied" : "Copy translation", action: copy)
                iconButton(item.pinned ? "pin.slash" : "pin", item.pinned ? "Unpin" : "Pin", action: togglePin)
                iconButton("trash", "Delete", action: remove)
            }
            .opacity(hover || selected ? 1 : 0)
            .offset(y: -3)
        }
        .padding(.horizontal, 8).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(hover ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hover = inside } }
        .onTapGesture(perform: open)
        .contextMenu {
            Button("Copy Translation", action: copy)
            Button("Copy Original") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.original, forType: .string)
            }
            Divider()
            Button(item.pinned ? LocalizedStringKey("Unpin") : LocalizedStringKey("Pin"), action: togglePin)
            Button("Delete", role: .destructive, action: remove)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.translated, forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { copied = false } }
    }

    private var languages: String {
        let code = { (id: String?) in id.map { makeLang($0).code } ?? "?" }
        return "\(code(item.source)) → \(code(item.target))"
    }

    private var time: String {
        let format = DateFormatter()
        format.dateFormat = Calendar.current.isDateInToday(item.date) ? "HH:mm" : "d MMM, HH:mm"
        return format.string(from: item.date)
    }

    private func iconButton(_ name: String, _ help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 10.5, weight: .medium)).frame(width: 22, height: 22)
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.secondary)
                .background(Circle().fill(Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain).help(help)
    }
}
