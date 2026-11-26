// "Send Feedback…": a small window where the person leaves their email and a message.
// It's posted to https://api.getlensy.app/feedback (a Cloudflare Worker, see feedback/worker.js), which emails it on.
// Sent along: the message, the email to reply to, and the app/macOS version — nothing else.

import AppKit
import SwiftUI

enum Feedback {
    static let endpoint = URL(string: "https://api.getlensy.app/feedback")!
    static let maxLength = 5000

    /// "Lensy 1.2.0 · macOS 15.4 · Apple Silicon" — what's needed to reproduce a bug, nothing personal.
    static var environment: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var chip = "Intel"
        #if arch(arm64)
        chip = "Apple Silicon"
        #endif
        return "Lensy \(version) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(chip)"
    }

    static func isValidEmail(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count <= 200 else { return false }
        return s.range(of: #"^[^\s@<>"]+@[^\s@<>"]+\.[^\s@<>"]+$"#, options: .regularExpression) != nil
    }

    static func canSend(email: String, message: String) -> Bool {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidEmail(email) && text.count >= 2 && text.count <= maxLength
    }

    struct Failure: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    static func request(email: String, message: String, endpoint: URL = endpoint) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "message": message.trimmingCharacters(in: .whitespacesAndNewlines),
            "app": environment,
        ])
        return request
    }

    /// Throws a Failure with a sentence that can be shown as is.
    static func send(email: String, message: String, endpoint: URL = endpoint, session: URLSession = .shared) async throws {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request(email: email, message: message, endpoint: endpoint))
        } catch {
            throw Failure(message: "Couldn’t reach the server — check your connection and try again.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status) { return }
        let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        throw Failure(message: reason ?? "Couldn’t send right now — please try again later.")
    }
}

struct FeedbackView: View {
    var close: () -> Void = {}
    var send: (String, String) async throws -> Void = { try await Feedback.send(email: $0, message: $1) }
    @AppStorage("feedbackEmail") private var email = ""
    @State private var message = ""
    @State private var sending = false
    @State private var sent = false
    @State private var error: String?
    @FocusState private var focus: Field?
    enum Field { case email, message }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if sent { thanks } else { form }
        }
        .padding(22)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var form: some View {
        Group {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send Feedback").font(.system(size: 16, weight: .semibold))
                    Text("Ideas, bugs, a language that reads badly — all welcome.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Your email").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                TextField("", text: $email, prompt: Text("you@example.com"))
                    .textFieldStyle(.roundedBorder).textContentType(.emailAddress).focused($focus, equals: .email)
                    .onSubmit { focus = .message }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Message").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                TextEditor(text: $message)
                    .font(.system(size: 13)).scrollContentBackground(.hidden).padding(6)
                    .frame(height: 130)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                    .focused($focus, equals: .message)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11.5)).foregroundStyle(.orange)
            }
            HStack {
                Text(Feedback.environment).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button {
                    Task { await submit() }
                } label: {
                    if sending { ProgressView().controlSize(.small).frame(width: 40) } else { Text("Send") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(sending || !Feedback.canSend(email: email, message: message))
            }
            .controlSize(.large)
        }
        .onAppear { focus = email.isEmpty ? .email : .message }
    }

    private var thanks: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.green)
            Text("Thank you!").font(.system(size: 16, weight: .semibold))
            Text("Your message is on its way. If it needs an answer, the reply goes to \(email).")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Done", action: close).buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction).padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    func submit() async {
        guard Feedback.canSend(email: email, message: message), !sending else { return }
        sending = true; error = nil
        do {
            try await send(email, message)
            withAnimation(.easeOut(duration: 0.2)) { sent = true }
        } catch {
            self.error = error.localizedDescription
        }
        sending = false
    }
}
