// The translation popup shown under the selection.

import AppKit
import SwiftUI
import Translation

struct PopupView: View {
    @ObservedObject var model: TranslationModel
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // language pills
            HStack(spacing: 4) {
                if let s = model.source {
                    Text((langs.first { $0.id == s } ?? makeLang(s)).code).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 2)
                }
                ForEach(langs) { l in
                    let on = l.id == model.target
                    Text(l.code)
                        .foregroundStyle(on ? Color.primary : Color.secondary.opacity(l.id == model.source ? 0.35 : 1))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background {
                            // one highlight that slides to the language picked with Tab
                            if on { Capsule().fill(Color.primary.opacity(0.12)).matchedGeometryEffect(id: "target", in: pill) }
                        }
                        .contentShape(Capsule())
                        .onTapGesture { if l.id != model.source { model.select(l.id) } }
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.mini) }
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .animation(Motion.list, value: model.target)

            // original
            if defaults.object(forKey: "showOriginal") as? Bool ?? true || model.problem != nil {
            Text(model.original)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            }

            // translation — shimmering skeleton while it loads
            ZStack(alignment: .topLeading) {
                if model.busy {
                    Skeleton(lines: skeletonLines)
                        .transition(.opacity)
                } else if let problem = model.problem {
                    ProblemView(problem: problem, source: model.source, target: model.target, fix: model.fix)
                        .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 3)))
                } else {
                    ScrollView {
                        Text(model.translated.isEmpty ? " " : model.translated)
                            .id(model.translated)                       // a new translation fades in instead of replacing the old one in place
                            .transition(.opacity)
                            .font(.system(size: 15, weight: .regular))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: 320)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 3)))
                }
            }
            .animation(.easeOut(duration: 0.22), value: model.busy)
            .animation(.easeOut(duration: 0.2), value: model.translated)
            .animation(.easeOut(duration: 0.2), value: model.problem)

            // hints
            HStack(spacing: 12) {
                switch model.problem {
                case .notDownloaded: hint("↩", "download")
                case .failed: hint("↩", "try again")
                default: EmptyView()
                }
                hint("⇥", "language"); hint("⌘C", model.copied ? "copied" : model.translated.isEmpty ? "copy text" : "copy")
                    .contentTransition(.opacity).animation(.easeOut(duration: 0.15), value: model.copied); hint("esc", "close")
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 420)
        .background(VisualEffect())
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .translationTask(model.config) { session in
            do {
                let r = try await session.translate(model.original)
                model.finish(r.targetText)
            } catch {
                model.fail(error.localizedDescription)
            }
        }
    }

    /// Roughly as many skeleton lines as the translation will take (≈ 48 chars per line at this width).
    var skeletonLines: Int { min(5, max(1, Int((Double(model.original.count) / 48).rounded(.up)))) }

    func hint(_ k: String, _ t: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Text(k).padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06)))
            Text(t)
        }
    }
}

/// Shown instead of the translation when it can't happen yet — always with a way forward.
struct ProblemView: View {
    let problem: TranslationModel.Problem
    let source: String?
    let target: String
    var fix: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let action {
                Button(action: fix) { Text(action) }.buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch problem {
        case .notDownloaded: "arrow.down.circle.fill"
        case .unsupported: "nosign"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch problem {
        case .notDownloaded: .accentColor
        case .unsupported: .secondary
        case .failed: .orange
        }
    }

    private var title: String {
        switch problem {
        case .notDownloaded(let ids):
            let names = ListFormatter.localizedString(byJoining: ids.map { makeLang($0).name })
            return ids.count == 1 ? String(localized: "\(names) isn’t downloaded yet") : String(localized: "\(names) aren’t downloaded yet")
        case .unsupported:
            let pair = (source.map { makeLang($0).name + " → " } ?? "") + makeLang(target).name
            return String(localized: "Apple can’t translate \(pair)")
        case .failed:
            return String(localized: "Couldn’t translate this")
        }
    }

    private var detail: String {
        switch problem {
        case .notDownloaded: String(localized: "Download it once — then translations work offline, right here.")
        case .unsupported: String(localized: "Press Tab to pick another language. ⌘C copies the text.")
        case .failed(let reason): reason
        }
    }

    private var action: String? {
        switch problem {
        case .notDownloaded: String(localized: "Download")
        case .failed: String(localized: "Try Again")
        case .unsupported: nil
        }
    }
}

/// Rounded grey bars with a soft highlight sweeping across — the "loading" placeholder.
struct Skeleton: View {
    let lines: Int
    @State private var phase: CGFloat = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(0..<lines, id: \.self) { i in
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.09))
                        .frame(width: g.size.width * width(i))
                }
                .frame(height: 12)
            }
        }
        .padding(.vertical, 3)
        .overlay(
            GeometryReader { g in
                LinearGradient(colors: [.clear, Color.white.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: g.size.width * 0.45)
                    .offset(x: phase * g.size.width * 1.45)
                    .blendMode(.plusLighter)
            }
            .mask(
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(0..<lines, id: \.self) { i in
                        GeometryReader { g in
                            RoundedRectangle(cornerRadius: 5, style: .continuous).frame(width: g.size.width * width(i))
                        }.frame(height: 12)
                    }
                }.padding(.vertical, 3)
            )
        )
        .onAppear {
            phase = -0.5
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }

    /// Natural-looking ragged line lengths; the last line is shorter.
    func width(_ i: Int) -> CGFloat {
        if i == lines - 1 { return lines == 1 ? 0.55 : 0.42 }
        return [0.97, 0.9, 0.94, 0.86][i % 4]
    }
}

