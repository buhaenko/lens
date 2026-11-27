// If Lensy crashed since it last ran, the history popover offers once to send a short report through Send Feedback.
// The report is macOS's own crash log (~/Library/Logs/DiagnosticReports/Lensy-*.ips), cut down to what explains
// the crash — exception, Lensy version, macOS, the crashed thread's functions — and shown in the message so the person
// sees exactly what goes out. No paths, no scanned text, nothing personal.

import AppKit
import SwiftUI

@MainActor final class CrashReports: ObservableObject {
    static let shared = CrashReports()

    /// A crash nobody has looked at yet.
    @Published private(set) var pending: String?

    nonisolated static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
    private let seenKey = "crashReportsSeen"

    /// On launch: the newest Lensy crash report written since the last check. The very first run only starts the clock.
    func check(folder: URL = CrashReports.folder, appName: String = History.folderName) {
        guard let seen = defaults.object(forKey: seenKey) as? Date else {
            defaults.set(Date(), forKey: seenKey)
            return
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = files
            .filter { $0.lastPathComponent.hasPrefix(appName + "-") && $0.pathExtension == "ips" }
            .compactMap { url in (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { (url, $0) } }
            .filter { $0.1 > seen }
            .max { $0.1 < $1.1 }
        guard let newest, let text = try? String(contentsOf: newest.0, encoding: .utf8) else { return }
        pending = Self.summary(of: text)
    }

    /// Done with it — sent or dismissed. Not offered again.
    func dismiss() {
        defaults.set(Date(), forKey: seenKey)
        withAnimation(Motion.quick) { pending = nil }
    }

    /// The parts of an .ips crash log that explain the crash. nil if it isn't one.
    nonisolated static func summary(of ips: String) -> String? {
        let parts = ips.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let header = try? JSONSerialization.jsonObject(with: Data(parts[0].utf8)) as? [String: Any],
              let body = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any] else { return nil }
        var lines = ["Lensy crashed"]
        let version = header["app_version"] as? String ?? "?"
        lines.append("Version: \(version.isEmpty ? "dev" : version) · \(header["os_version"] as? String ?? "macOS ?")")
        if let time = header["timestamp"] as? String { lines.append("When: \(time)") }
        if let exception = body["exception"] as? [String: Any] {
            lines.append("Exception: " + [exception["type"], exception["signal"]].compactMap { $0 as? String }.joined(separator: " · "))
        }
        if let reasons = (body["asi"] as? [String: [String]])?.values.flatMap({ $0 }), !reasons.isEmpty {
            lines.append("Reason: " + reasons.joined(separator: " ").prefix(400))
        }
        let images = (body["usedImages"] as? [[String: Any]])?.map { $0["name"] as? String ?? "?" } ?? []
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = body["faultingThread"] as? Int ?? threads.firstIndex { $0["triggered"] as? Bool == true } ?? 0
        if threads.indices.contains(faulting), let frames = threads[faulting]["frames"] as? [[String: Any]] {
            lines.append("Crashed thread:")
            for (i, frame) in frames.prefix(25).enumerated() {
                let image = (frame["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0] : nil } ?? "?"
                let symbol = frame["symbol"] as? String ?? String(format: "0x%llx", frame["imageOffset"] as? Int ?? 0)
                lines.append("\(i)  \(image)  \(symbol)")
            }
        }
        return String(lines.joined(separator: "\n").prefix(Feedback.maxLength - 200))
    }
}

/// "Lensy quit unexpectedly" with Send Report — once per crash.
struct CrashBanner: View {
    @ObservedObject var crashes = CrashReports.shared

    var body: some View {
        if let report = crashes.pending {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
                Text("Lensy quit unexpectedly last time").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Send Report") {
                    NotificationCenter.default.post(name: FeedbackView.open, object: report)
                    crashes.dismiss()
                }
                .buttonStyle(.borderless).font(.system(size: 11, weight: .medium))
                Button { crashes.dismiss() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                    .buttonStyle(.borderless).foregroundStyle(.tertiary).help(String(localized: "Dismiss"))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.1)))
            .padding(.horizontal, 12).padding(.bottom, 8)
            .transition(.opacity)
        }
    }
}
