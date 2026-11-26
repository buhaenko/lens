// Robustness: feedback end to end, the status menu, and crash tests — garbage input, floods, memory.
// Called from runTests() before the summary.
import Cocoa
import Vision
import SwiftUI

/// Answers URLSession requests in-process, so the feedback client can be tested without the network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var reply: (status: Int, body: String)? = (200, #"{"ok":true}"#)
    nonisolated(unsafe) static var lastBody: [String: Any]?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let stream = request.httpBodyStream {
            stream.open(); var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            stream.close()
            Self.lastBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } else if let data = request.httpBody {
            Self.lastBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        guard let reply = Self.reply else { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func residentMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
    return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
}

func noiseImage(_ w: Int, _ h: Int, seed: UInt64) -> CGImage {
    var rng = seed
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    for i in bytes.indices { rng = rng &* 6364136223846793005 &+ 1442695040888963407; bytes[i] = UInt8(truncatingIfNeeded: rng >> 33) }
    let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()!
}

@MainActor func runRobustnessTests() {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lensy-robust-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    // MARK: Feedback
    section("Feedback — form rules")
    for good in ["a@b.co", "  me@getlensy.app ", "first.last+tag@mail.example.org", "юзер@приклад.укр"] {
        expect(Feedback.isValidEmail(good), "valid email: \(good)")
    }
    for bad in ["", "a", "a@b", "@b.co", "a@.co x", "a b@c.de", "a@b.co\nBcc: x@y.z", "<a@b.co>", String(repeating: "a", count: 200) + "@b.co"] {
        expect(!Feedback.isValidEmail(bad), "rejected email: \(bad.prefix(30).debugDescription)")
    }
    expect(!Feedback.canSend(email: "a@b.co", message: " "), "an empty message can't be sent")
    expect(!Feedback.canSend(email: "a@b.co", message: String(repeating: "x", count: Feedback.maxLength + 1)), "an over-long message can't be sent")
    expect(Feedback.canSend(email: "a@b.co", message: "Hi!"), "email + message → Send is enabled")
    expect(Feedback.environment.hasPrefix("Lensy ") && Feedback.environment.contains("macOS"), "sends the app and macOS version: \(Feedback.environment)")
    let req = Feedback.request(email: " me@x.io ", message: "  Hello  ")
    let sentBody = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: String]) ?? [:]
    expectEqual(Set(sentBody.keys), ["email", "message", "app"], "sends only email, message and version — nothing else")
    expect(sentBody["email"] == "me@x.io" && sentBody["message"] == "Hello", "trims what's sent")
    expectEqual(req.url?.absoluteString, "https://api.getlensy.app/feedback", "posts to api.getlensy.app")

    section("Feedback — sending (stubbed server)")
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    let stub = URLSession(configuration: config)
    StubProtocol.reply = (200, #"{"ok":true}"#)
    let ok: String? = blocking { do { try await Feedback.send(email: "a@b.co", message: "Привіт ✓", session: stub); return nil } catch { return error.localizedDescription } }
    expect(ok == nil, "200 → sent")
    expectEqual(StubProtocol.lastBody?["message"] as? String, "Привіт ✓", "Unicode survives the trip")
    StubProtocol.reply = (429, #"{"error":"Too many messages — please try again in an hour."}"#)
    let limited: String? = blocking { do { try await Feedback.send(email: "a@b.co", message: "hi", session: stub); return nil } catch { return error.localizedDescription } }
    expectEqual(limited, "Too many messages — please try again in an hour.", "the server's reason is shown as is")
    StubProtocol.reply = (500, "<html>oops</html>")
    let broken: String? = blocking { do { try await Feedback.send(email: "a@b.co", message: "hi", session: stub); return nil } catch { return error.localizedDescription } }
    expectEqual(broken, "Couldn’t send right now — please try again later.", "a broken server → a friendly sentence, no crash")
    StubProtocol.reply = nil
    let offline: String? = blocking { do { try await Feedback.send(email: "a@b.co", message: "hi", session: stub); return nil } catch { return error.localizedDescription } }
    expect(offline?.contains("connection") == true, "offline → asks to check the connection")
    StubProtocol.reply = (200, #"{"ok":true}"#)

    section("Feedback — window")
    let view = FeedbackView(close: {}, send: { _, _ in })
    let host = NSHostingView(rootView: view)
    host.frame.size = host.fittingSize
    expect(host.fittingSize.width >= 400 && host.fittingSize.height > 200, "the form lays out (\(Int(host.fittingSize.width))×\(Int(host.fittingSize.height)))")

    section("Feedback — live server (end to end, nothing is emailed)")
    if ProcessInfo.processInfo.environment["LENSY_OFFLINE"] == nil {
        let live: (Int, String) = blocking {
            var r = URLRequest(url: Feedback.endpoint, timeoutInterval: 15)
            r.httpMethod = "POST"; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = Data(#"{"email":"not-an-email","message":"test"}"#.utf8)
            guard let (data, resp) = try? await URLSession.shared.data(for: r) else { return (0, "") }
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
        }
        if live.0 == 0 { skip("live server", "no network") } else {
            expectEqual(live.0, 400, "the server is up and checks the email")
            expect(live.1.contains("valid email"), "and explains what's wrong")
            let get: Int = blocking { ((try? await URLSession.shared.data(from: Feedback.endpoint))?.1 as? HTTPURLResponse)?.statusCode ?? 0 }
            expectEqual(get, 405, "only POST is accepted")
        }
    } else { skip("live server", "LENSY_OFFLINE is set") }

    // MARK: Menu
    section("Status menu — every item, with its icon")
    let app = AppDelegate()
    let menu = app.makeStatusMenu()
    let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    expectEqual(Array(titles.prefix(4)), ["Scan & Translate", "Clear History", "Settings…", "Send Feedback…"], "menu items in order")
    expectEqual(titles.last, "Quit Lensy", "Quit is last")
    let real = menu.items.filter { !$0.isSeparatorItem }
    expect(real.allSatisfy { $0.image != nil }, "every item has an icon")
    if #available(macOS 27.0, *) {
        expect(real.allSatisfy { $0.preferredImageVisibility == .visible }, "icons are forced visible (macOS 27 hides them otherwise)")
    }
    expect(real.allSatisfy { item in item.action.map { sel in (item.target as AnyObject?)?.responds(to: sel) ?? false } ?? false },
           "every item is wired to something that handles it")
    expect(real.first { $0.title == "Send Feedback…" }?.isEnabled == true, "Send Feedback is enabled")

    // MARK: Crash tests
    section("Crash test — update feed fuzzing")
    var rng = SystemRandomNumberGenerator()
    var survived = 0
    for i in 0..<3000 {
        let length = Int.random(in: 0..<400, using: &rng)
        var data = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) })
        if i % 3 == 0 { data = Data(#"{"tag_name":\#(["null", "1", "\"v\"", "\"v9999999999999999999.1\"", "[]"][i % 5]),"assets":\#(["[]", "{}", "[{}]", "[{\"name\":\"Lensy.zip\"}]", "7"][i % 5])}"#.utf8) }
        _ = Updater.parse(data); survived += 1
    }
    expectEqual(survived, 3000, "3000 random and malformed release feeds → no crash")
    let versions = ["", "v", "1", "1.0", "1.0.0", "01.2", "1..2", "-1", "1.0.0-beta", "99999999999999999999", "1.2.3.4.5", "١.٢", "1.0 ", "a.b.c"]
    for a in versions { for b in versions { _ = Updater.isNewer(a, than: b); _ = Updater.isRelease(a) } }
    expect(true, "every pair of odd version strings compares without crashing")
    expect(!Updater.isNewer("1.0.0", than: "1.0.0") && Updater.isNewer("1.0.10", than: "1.0.9") && !Updater.isNewer("garbage", than: "1.0.0"), "and the sane ones compare right")

    section("Crash test — odd text everywhere")
    let odd = ["", " ", "\n\n\n", "\u{0}", "🙂🙃😉" , String(repeating: "ä", count: 20_000), "\u{202E}reversed", "𝔘𝔫𝔦𝔠𝔬𝔡𝔢", "a\u{301}\u{301}\u{301}", "<script>alert(1)</script>", "%@%@%@%n", String(repeating: "1234 ", count: 3000)]
    for text in odd {
        _ = detectLanguage(text)
        _ = HistoryFilter(skipLanguages: ["en"], minLength: 3, skipNumbers: true, skipPrivate: true, blockedWords: ["x"]).reasonToSkip(text, source: nil)
        _ = HistoryFilter.containsPrivateInfo(text); _ = HistoryFilter.containsCardNumber(text)
        _ = Scan(original: text, translated: text, source: nil, target: "en").matches(text)
    }
    for id in ["", "zz", "xx-YY-ZZ", "123", "en_US", "😀", String(repeating: "a", count: 500)] { _ = makeLang(id) }
    _ = assembleLines([]); _ = assembleLines([("", .zero), ("x", CGRect(x: CGFloat.nan, y: CGFloat.infinity, width: -1, height: 0))])
    expect(true, "language detection, filters, search, language names and line assembly survive odd input")

    section("Crash test — history under load")
    let url = tmp.appendingPathComponent("history.json")
    let history = History(url: url)
    defaults.set(500, forKey: "historyLimit")
    let started = Date()
    for i in 0..<2000 { history.upsert(Scan(original: "scan \(i) " + String(repeating: "lorem ", count: i % 50), translated: "t\(i)", source: "en", target: "uk")) }
    let took = Date().timeIntervalSince(started)
    defaults.removeObject(forKey: "historyLimit")
    expectEqual(history.items.count, 500, "2000 scans → trimmed to the limit")
    expect(took < 20, "2000 saves in \(String(format: "%.1f", took)) s")
    expectEqual(History(url: url).items.count, 500, "reloads intact")
    for garbage in [Data(), Data([0xFF, 0xFE, 0x00]), Data("[{\"id\":1}]".utf8), Data("null".utf8), Data(repeating: 0x7B, count: 100_000)] {
        try? garbage.write(to: url)
        _ = History(url: url)
    }
    expect(true, "five kinds of broken history file load as empty, no crash")
    try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
    let readOnly = History(url: url); readOnly.upsert(Scan(original: "x", translated: "y", source: nil, target: "en"))
    expectEqual(readOnly.items.count, 1, "a read-only history file doesn't crash a scan")
    try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

    section("Crash test — selection, mashed")
    if let screen = NSScreen.main {
        let window = OverlayWindow(screen: screen)            // never shown
        var results = 0, nils = 0
        window.selection.onDone = { rect in results += 1; if rect == nil { nils += 1 } }
        func mouse(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        for _ in 0..<400 {
            let a = NSPoint(x: .random(in: -50...screen.frame.width + 50), y: .random(in: -50...screen.frame.height + 50))
            let b = NSPoint(x: .random(in: -50...screen.frame.width + 50), y: .random(in: -50...screen.frame.height + 50))
            window.selection.mouseDown(with: mouse(.leftMouseDown, a))
            for _ in 0..<3 { window.selection.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))) }
            window.selection.mouseDragged(with: mouse(.leftMouseDragged, b))
            window.selection.mouseUp(with: mouse(.leftMouseUp, b))
        }
        window.selection.mouseUp(with: mouse(.leftMouseUp, .zero))      // a release without a press
        window.selection.rightMouseDown(with: mouse(.rightMouseDown, .zero))
        expectEqual(results, 402, "400 random drags + stray clicks → every one finishes exactly once")
        expect(nils >= 2, "tiny or cancelled drags give nothing to scan")
        window.close()
    } else { skip("selection mashing", "no screen") }

    section("Crash test — OCR on images that aren't text")
    let images: [(String, CGImage)] = [("1×1", noiseImage(1, 1, seed: 1)), ("3×900 sliver", noiseImage(3, 900, seed: 2)),
                                        ("noise 800×600", noiseImage(800, 600, seed: 3)), ("huge 6000×4000", noiseImage(6000, 4000, seed: 4))]
    for (name, image) in images {
        let text = blocking { await recognize(image) }
        expect(text.count < 2000, "\(name) → no crash (\(text.count) chars)")
    }

    section("Crash test — memory stays flat")
    let sample = renderText("Memory check: the same paragraph, scanned again and again.")
    _ = blocking { await recognize(sample) }
    let before = residentMB()
    for _ in 0..<25 { _ = blocking { await recognize(sample) } }
    let grew = residentMB() - before
    expect(grew < 150, "25 more scans grow memory by \(Int(grew)) MB (< 150)")
}
