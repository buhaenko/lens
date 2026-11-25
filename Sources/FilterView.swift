// History filters, shown in a popover from Settings.

import SwiftUI
import Translation

struct FilterView: View {
    @State private var filter = HistoryFilter.current
    @State private var words = HistoryFilter.current.blockedWords.joined(separator: ", ")
    @State private var available: [String] = []
    @State private var cleaned: Int?
    var changed: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("History filters").font(.system(size: 13, weight: .semibold))
                Text("Everything is still translated — filters only decide what’s remembered.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                label("Don’t save text in")
                FlowChips(items: filter.skipLanguages.map(makeLang), remove: { id in filter.skipLanguages.removeAll { $0 == id } }) {
                    Menu {
                        ForEach(languageChoices, id: \.self) { id in Button(makeLang(id).name) { filter.skipLanguages.append(id) } }
                    } label: {
                        Label("Language", systemImage: "plus").font(.system(size: 11.5))
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).foregroundStyle(.secondary).fixedSize()
                }
            }

            VStack(spacing: 0) {
                toggle("Numbers, prices and codes", detail: "“€ 12,99”, “08:30”, “#A7F3”", $filter.skipNumbers)
                Divider()
                toggle("Private info", detail: "Emails, links, phone, card and IBAN numbers", $filter.skipPrivate)
                Divider()
                HStack {
                    Text("Shorter than").font(.system(size: 12.5))
                    Spacer()
                    Picker("", selection: $filter.minLength) {
                        Text("Off").tag(0)
                        ForEach([4, 10, 25], id: \.self) { Text("\($0) characters").tag($0) }
                    }
                    .labelsHidden().fixedSize().controlSize(.small)
                }
                .frame(height: 34)
            }

            VStack(alignment: .leading, spacing: 6) {
                label("Text containing")
                TextField("password, invoice, …", text: $words)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
                    .onChange(of: words) { _, list in filter.blockedWords = HistoryFilter.words(from: list) }
            }

            Divider()
            HStack {
                Button("Apply to saved scans") { cleaned = History.shared.apply(filter) }
                    .controlSize(.small).disabled(filter.activeCount == 0)
                Spacer()
                if let cleaned {
                    Text(cleaned == 0 ? "Nothing to remove" : "Removed \(cleaned) · pinned kept")
                        .font(.system(size: 11)).foregroundStyle(.secondary).transition(.opacity)
                }
            }
        }
        .padding(16)
        .frame(width: 340)
        .onChange(of: filter) { _, value in HistoryFilter.current = value; cleaned = nil; changed() }
        .task {
            let languages = await LanguageAvailability().supportedLanguages
            available = Array(Set(languages.compactMap { $0.languageCode?.identifier }))
        }
    }

    /// Your own languages first, then everything else Apple can translate.
    private var languageChoices: [String] {
        let mine = langs.map(\.id)
        let rest = available.filter { !mine.contains($0) }.sorted { makeLang($0).name.localizedCompare(makeLang($1).name) == .orderedAscending }
        return (mine + rest).filter { !filter.skipLanguages.contains($0) }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
    }

    private func toggle(_ title: String, detail: String, _ value: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5))
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            Spacer()
            Toggle("", isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
        .frame(height: 40)
    }
}

/// Language chips that wrap onto new lines, followed by an add button.
private struct FlowChips<Add: View>: View {
    let items: [Lang]
    var remove: (String) -> Void
    @ViewBuilder var add: () -> Add

    var body: some View {
        Flow(spacing: 6) {
            ForEach(items) { lang in
                HStack(spacing: 4) {
                    Text(lang.name).font(.system(size: 11.5))
                    Button { remove(lang.id) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove")
                }
                .padding(.leading, 8).padding(.trailing, 6).frame(height: 22)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            add().frame(height: 22)
        }
    }
}

/// Minimal wrapping layout.
private struct Flow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty && rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            let gap = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += gap + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
