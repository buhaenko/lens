// Menu bar popover: history of scans and permission hints.

import AppKit
import SwiftUI
import Combine

struct HistoryView: View {
    @ObservedObject var history = History.shared
    var open: (Scan) -> Void
    var scan: () -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var pinned: [Scan] { history.pinned.filter { $0.matches(query) } }
    private var recent: [Scan] { history.recent.filter { $0.matches(query) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Lensy").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: scan) {
                    Label("Scan", systemImage: "text.viewfinder").font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help("\(shortcutHint()) · right-click the icon for Settings")
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            PermissionBanner()

            if history.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkle").font(.system(size: 24, weight: .light)).foregroundStyle(.tertiary)
                    Text("No scans yet").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Text("\(shortcutHint()), then select text").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity).padding(.top, 28).padding(.bottom, 36)
            } else {
                searchField
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !pinned.isEmpty {
                            sectionTitle("Pinned", systemImage: "pin.fill")
                            rows(pinned)
                            if !recent.isEmpty { sectionTitle("Recent", systemImage: "clock") }
                        }
                        rows(recent)
                        if pinned.isEmpty && recent.isEmpty {
                            Text("Nothing matches “\(query)”")
                                .font(.system(size: 12)).foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity).padding(.vertical, 28)
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 8)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 480)
                .fixedSize(horizontal: false, vertical: true)

                Divider().opacity(0.5)
                HStack {
                    Text(summary).font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                    Button(history.pinned.isEmpty ? "Clear" : "Clear unpinned") { withAnimation { history.clear() } }
                        .buttonStyle(.borderless).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .disabled(history.recent.isEmpty)
                }
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 12)
            }
        }
        .frame(width: 360)
        .onAppear { query = ""; searchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain).font(.system(size: 12.5))
                .focused($searchFocused)
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
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

    @ViewBuilder private func rows(_ scans: [Scan]) -> some View {
        ForEach(Array(scans.enumerated()), id: \.element.id) { index, item in
            if index > 0 { Divider().opacity(0.5).padding(.horizontal, 8) }
            ScanRow(item: item, open: { open(item) },
                    togglePin: { withAnimation(.easeOut(duration: 0.2)) { history.togglePin(item.id) } },
                    remove: { withAnimation(.easeOut(duration: 0.2)) { history.remove(item.id) } })
        }
    }

    private var summary: String {
        let count = history.items.count
        let pins = history.pinned.count
        return "\(count) \(count == 1 ? "scan" : "scans")" + (pins > 0 ? " · \(pins) pinned" : "")
    }
}

/// Shows what's missing for the shortcut / capture to work, with a button straight to the right Settings pane.
struct PermissionBanner: View {
    @State private var hasAccessibility = Permissions.accessibility
    @State private var hasScreenRecording = Permissions.screenRecording
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 6) {
            if !hasAccessibility { row("The quick-scan key needs Accessibility", .accessibility) }
            if !hasScreenRecording { row("Scanning needs Screen Recording", .screenRecording) }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, (hasAccessibility && hasScreenRecording) ? 0 : 8)
        .onReceive(timer) { _ in hasAccessibility = Permissions.accessibility; hasScreenRecording = Permissions.screenRecording }
    }

    func row(_ text: String, _ pane: Permissions.Pane) -> some View {
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
            .opacity(hover ? 1 : 0)
            .offset(y: -3)
        }
        .padding(.horizontal, 8).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(hover ? 0.06 : 0)))
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
            Button(item.pinned ? "Unpin" : "Pin", action: togglePin)
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

    private func iconButton(_ name: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 10.5, weight: .medium)).frame(width: 22, height: 22)
                .foregroundStyle(.secondary)
                .background(Circle().fill(Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain).help(help)
    }
}
