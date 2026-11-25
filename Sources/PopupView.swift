// The translation popup shown under the selection.

import AppKit
import SwiftUI
import Translation

struct PopupView: View {
    @ObservedObject var model: TranslationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // language pills
            HStack(spacing: 4) {
                if let s = model.source, let l = langs.first(where: { $0.id == s }) {
                    Text(l.code).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 2)
                }
                ForEach(langs) { l in
                    let on = l.id == model.target
                    Text(l.code)
                        .foregroundStyle(on ? Color.primary : Color.secondary.opacity(l.id == model.source ? 0.35 : 1))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(on ? Color.primary.opacity(0.12) : .clear))
                        .contentShape(Capsule())
                        .onTapGesture { if l.id != model.source { model.select(l.id) } }
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.mini) }
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .animation(.easeOut(duration: 0.15), value: model.target)

            // original
            if defaults.object(forKey: "showOriginal") as? Bool ?? true {
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
                } else {
                    ScrollView {
                        Text(model.translated.isEmpty ? " " : model.translated)
                            .font(.system(size: 15, weight: .regular))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: 320)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .offset(y: 3)))
                }
            }
            .animation(.easeOut(duration: 0.22), value: model.busy)

            // hints
            HStack(spacing: 12) {
                hint("⇥", "language"); hint("⌘C", model.copied ? "copied" : "copy"); hint("esc", "close")
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
                model.translated = r.targetText
                model.record()
            } catch {
                model.translated = "Translation unavailable for this pair.\n\(error.localizedDescription)"
            }
            model.busy = false
        }
    }

    /// Roughly as many skeleton lines as the translation will take (≈ 48 chars per line at this width).
    var skeletonLines: Int { min(5, max(1, Int((Double(model.original.count) / 48).rounded(.up)))) }

    func hint(_ k: String, _ t: String) -> some View {
        HStack(spacing: 4) {
            Text(k).padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06)))
            Text(t)
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

