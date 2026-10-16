import Darwin
import Foundation

/// Lets myOS use LaVoix's engine. A Unix socket in the owner-only folder `~/Library/Application Support/myOS/private/`
/// (the same place as the message store), NOT a TCP port: any process on the Mac can reach a port, only this user can reach
/// this file. One request per connection, one JSON line in; the reply is one JSON line, or for streaming operations a
/// sequence of lines ending with a `done` or `error` event. The prompts can contain message text, so nothing logs them.
///
///   {"op":"status"}                                       -> {"ok":true,"model":"...","downloaded":true,"loaded":false}
///   {"op":"warm"}                                         -> {"ok":true}   (starts loading the model; returns at once)
///   {"op":"generate","system","user","max_tokens"}        -> {"ok":true,"text":"...","ms":1234}
///   {"op":"generate_stream","system","user","max_tokens"} -> {"event":"token","text":"..."} ... {"event":"done","ms":1234}
///   {"op":"meetings.list"}                                -> {"ok":true,"meetings":[...]}
///   {"op":"meetings.get","id"}                            -> {"ok":true,"meeting":{...}}
///   {"op":"meetings.live"}                                -> {"ok":true,"live":{"active":true,"id","title","started_at","elapsed_seconds","rows":[{"speaker":"you|them","text","partial"}]}}
///   {"op":"meetings.notes_save","id","text"}              -> {"ok":true}
///   {"op":"meetings.notes_generate","id","kind","auto"}   -> {"event":"progress","message"} ... {"event":"done","text"}
/// Failures come back as {"ok":false,"error":"..."} (streams: {"event":"error","error":"..."}).
nonisolated enum EngineSocket {
    static let maxRequestBytes = 1_000_000
    private static let enabledKey = "LaVoixEngineSocketEnabled"

    /// On by default: it only serves the signed-in user and only runs the local model.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: self.enabledKey) }
    }

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/myOS/private/engine.sock")
    }

    /// What the engine can do; injected so the autotest never needs a model or real meetings.
    typealias Generator = @Sendable (_ system: String, _ user: String, _ maxTokens: Int) async throws -> String
    typealias StreamGenerator = @Sendable (_ system: String, _ user: String, _ maxTokens: Int) async throws -> AsyncThrowingStream<String, Error>
    typealias StatusProvider = @Sendable () async -> (model: String, downloaded: Bool, loaded: Bool)
    typealias Warmer = @Sendable () -> Void

    struct Services: @unchecked Sendable {
        var generator: Generator
        var streamGenerator: StreamGenerator?
        var status: StatusProvider
        var warm: Warmer = {}
        var meetings: (any EngineMeetingsProviding)?
    }

    private static let lock = NSLock()
    /// One listener per socket path (the autotest serves a temp path while the app serves the real one).
    private nonisolated(unsafe) static var listeners: [String: Int32] = [:]

    static func startIfEnabled() {
        guard self.isEnabled, ProcessInfo.processInfo.environment["LAVOIX_ENGINE_SOCKET_AUTOTEST"] != "1" else { return }
        _ = self.start(at: self.defaultURL, services: self.liveServices)
    }

    static let liveGenerator: Generator = { system, user, maxTokens in
        let modelID = LocalCleanupSettings.modelID
        guard LocalCleanupProvider.isDownloaded(modelID: modelID) else { throw EngineError.modelMissing }
        return try await LocalCleanupEngine.shared.generate(
            system: system, user: user, modelID: modelID, maxTokens: maxTokens, temperature: 0, cachesPrefix: false
        )
    }

    static let liveStreamGenerator: StreamGenerator = { system, user, maxTokens in
        let modelID = LocalCleanupSettings.modelID
        guard LocalCleanupProvider.isDownloaded(modelID: modelID) else { throw EngineError.modelMissing }
        return try await LocalCleanupEngine.shared.generateStream(system: system, user: user, modelID: modelID, maxTokens: maxTokens)
    }

    static let liveStatus: StatusProvider = {
        let id = LocalCleanupSettings.modelID
        return (id, LocalCleanupProvider.isDownloaded(modelID: id), await LocalCleanupEngine.shared.isLoaded)
    }

    static let liveWarmer: Warmer = {
        let id = LocalCleanupSettings.modelID
        guard LocalCleanupProvider.isDownloaded(modelID: id) else { return }
        Task.detached(priority: .utility) { try? await LocalCleanupEngine.shared.prepare(modelID: id) }
    }

    static var liveServices: Services {
        Services(generator: self.liveGenerator, streamGenerator: self.liveStreamGenerator, status: self.liveStatus, warm: self.liveWarmer, meetings: LiveEngineMeetings())
    }

    enum EngineError: LocalizedError {
        case modelMissing
        var errorDescription: String? { "The on-device model is not downloaded yet. Open myOS, then AI Providers, to download it." }
    }

    /// Binds the socket and serves it on background queues. Returns false if it could not (path too long, folder not writable).
    @discardableResult
    static func start(at url: URL, services: Services) -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        if self.listeners[url.path] != nil { return true }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        unlink(url.path) // a stale socket from a crashed run

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(url.path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in pathBytes.enumerated() { raw[i] = b }
            raw[pathBytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { close(fd); return false }
        chmod(url.path, 0o600)
        guard listen(fd, 8) == 0 else { close(fd); unlink(url.path); return false }
        self.listeners[url.path] = fd

        DispatchQueue.global(qos: .utility).async {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { if errno == EINTR { continue }; break } // closed by stop()
                self.serve(client: client, services: services)
            }
        }
        return true
    }

    static func stop(removing url: URL = EngineSocket.defaultURL) {
        self.lock.lock(); defer { self.lock.unlock() }
        if let fd = self.listeners.removeValue(forKey: url.path) { close(fd) }
        unlink(url.path)
    }

    private static func serve(client: Int32, services: Services) {
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 10, tv_usec: 0) // a client that goes quiet cannot hold a thread
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == geteuid() else { close(client); return }

        DispatchQueue.global(qos: .utility).async {
            let request = self.readLine(client)
            Task.detached {
                // Each line is written as it is produced; false tells a long-running operation that nobody is listening.
                let emit: @Sendable ([String: Any]) -> Bool = { object in
                    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(#"{"ok":false,"error":"encode"}"#.utf8)
                    return self.writeAll(client, data + Data("\n".utf8))
                }
                await self.handle(line: request, services: services, emit: emit)
                close(client)
            }
        }
    }

    /// Pure request -> lines, so the protocol can be tested without sockets or a model.
    static func handle(line: Data?, services: Services, emit: @escaping @Sendable ([String: Any]) -> Bool) async {
        func fail(_ message: String) { _ = emit(["ok": false, "error": message]) }
        guard let line, !line.isEmpty else { return fail("empty request") }
        guard line.count <= self.maxRequestBytes else { return fail("request too large") }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let op = object["op"] as? String else {
            return fail("not a JSON object with an op")
        }
        func uuid() -> UUID? { (object["id"] as? String).flatMap(UUID.init(uuidString:)) }
        func message(_ error: Error) -> String { (error as? LocalizedError)?.errorDescription ?? "failed" }
        let maxTokens = min(max((object["max_tokens"] as? Int) ?? 400, 16), 800)

        switch op {
        case "status":
            let s = await services.status()
            _ = emit(["ok": true, "model": s.model, "downloaded": s.downloaded, "loaded": s.loaded])
        case "warm":
            services.warm()
            _ = emit(["ok": true])
        case "generate":
            guard let user = object["user"] as? String, !user.isEmpty else { return fail("missing user") }
            let start = Date()
            do {
                let text = try await services.generator(object["system"] as? String ?? "", user, maxTokens)
                _ = emit(["ok": true, "text": text, "ms": Int(Date().timeIntervalSince(start) * 1000)])
            } catch { fail(message(error)) }
        case "generate_stream":
            guard let user = object["user"] as? String, !user.isEmpty else { return _ = emit(["event": "error", "error": "missing user"]) }
            guard let stream = services.streamGenerator else { return _ = emit(["event": "error", "error": "streaming is not available"]) }
            let start = Date()
            do {
                for try await piece in try await stream(object["system"] as? String ?? "", user, maxTokens) {
                    if !emit(["event": "token", "text": piece]) { return } // the listener left: stop generating
                }
                _ = emit(["event": "done", "ms": Int(Date().timeIntervalSince(start) * 1000)])
            } catch { _ = emit(["event": "error", "error": message(error)]) }
        case "meetings.list", "meetings.get", "meetings.notes_save", "meetings.notes_generate", "meetings.live":
            guard let meetings = services.meetings else { return fail("meetings are not available") }
            do {
                switch op {
                case "meetings.live":
                    _ = emit(["ok": true, "live": await meetings.live()])
                case "meetings.list":
                    _ = emit(["ok": true, "meetings": try await meetings.list()])
                case "meetings.get":
                    guard let id = uuid() else { return fail("missing or bad id") }
                    guard let meeting = try await meetings.get(id: id) else { return fail(EngineMeetingsError.notFound.errorDescription ?? "not found") }
                    _ = emit(["ok": true, "meeting": meeting])
                case "meetings.notes_save":
                    guard let id = uuid(), let text = object["text"] as? String else { return fail("missing id or text") }
                    try await meetings.saveNotes(id: id, text: text)
                    _ = emit(["ok": true])
                default:
                    guard let id = uuid() else { return _ = emit(["event": "error", "error": "missing or bad id"]) }
                    try await meetings.generateNotes(id: id, kind: object["kind"] as? String ?? "executive", auto: object["auto"] as? Bool ?? false, emit: emit)
                }
            } catch {
                _ = op == "meetings.notes_generate" ? emit(["event": "error", "error": message(error)]) : emit(["ok": false, "error": message(error)])
            }
        default:
            fail("unknown op")
        }
    }

    private static func readLine(_ fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while data.count <= self.maxRequestBytes + 1 {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
            if let newline = data.firstIndex(of: 0x0A) { return data.prefix(upTo: newline) }
        }
        return data.isEmpty ? nil : data
    }

    @discardableResult
    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }
}

// MARK: - Autotest

private final class AutotestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { self.lock.lock(); self.flag = true; self.lock.unlock() }
    var value: Bool { self.lock.lock(); defer { self.lock.unlock() }; return self.flag }
}

/// Meetings with made-up content, so the protocol can be exercised end to end without the real store.
private struct FakeMeetings: EngineMeetingsProviding {
    let notesSaved: AutotestFlag
    let knownID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    func list() async throws -> [[String: Any]] { [["id": self.knownID.uuidString, "title": "Design sync", "words": 120]] }
    func get(id: UUID) async throws -> [String: Any]? {
        id == self.knownID ? ["id": id.uuidString, "title": "Design sync", "segments": [["start": 0.0, "speaker": "Me", "text": "hello"]]] : nil
    }
    func live() async -> [String: Any] {
        ["active": true, "id": self.knownID.uuidString, "title": "Design sync", "elapsed_seconds": 95, "rows": [["speaker": "you", "text": "hello", "partial": false], ["speaker": "them", "text": "hi the", "partial": true]]]
    }
    func saveNotes(id: UUID, text: String) async throws {
        guard id == self.knownID else { throw EngineMeetingsError.notFound }
        if text == "my notes" { self.notesSaved.set() }
    }
    func generateNotes(id: UUID, kind: String, auto: Bool, emit: @escaping @Sendable ([String: Any]) -> Bool) async throws {
        guard id == self.knownID else { throw EngineMeetingsError.notFound }
        if auto { _ = emit(["event": "skipped", "reason": "not needed"]); return }
        _ = emit(["event": "progress", "message": "Reading part 1 of 2…"])
        _ = emit(["event": "progress", "message": "Reading part 2 of 2…"])
        _ = emit(["event": "done", "text": "notes for \(kind)"])
    }
}

/// `LAVOIX_ENGINE_SOCKET_AUTOTEST=1` serves fakes on a temp socket and talks to it as a client.
nonisolated enum EngineSocketAutotest {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["LAVOIX_ENGINE_SOCKET_AUTOTEST"] == "1" else { return }
        Task.detached {
            var failures = 0
            func check(_ name: String, _ ok: Bool) { print((ok ? "PASS " : "FAIL ") + name); if !ok { failures += 1 } }
            // Unix socket paths top out at 104 bytes, so the system temp folder (very long on macOS) is too deep.
            let base = URL(fileURLWithPath: "/tmp/lve-\(UUID().uuidString.prefix(8))")
            let url = base.appendingPathComponent("private/engine.sock")
            let secret = "SECRET-PLANTED-TEXT"
            let warmed = AutotestFlag()
            let notesSaved = AutotestFlag()
            let services = EngineSocket.Services(
                generator: { system, user, maxTokens in
                    if user.contains("explode") { throw NSError(domain: "t", code: 1) }
                    return "echo(\(system.count),\(user.count),\(maxTokens)):" + user.uppercased()
                },
                streamGenerator: { _, user, _ in
                    AsyncThrowingStream { continuation in
                        Task {
                            if user.contains("explode") { continuation.finish(throwing: NSError(domain: "t", code: 2)); return }
                            for word in user.split(separator: " ") { continuation.yield(String(word) + " "); try? await Task.sleep(nanoseconds: 2_000_000) }
                            continuation.finish()
                        }
                    }
                },
                status: { ("test-model", true, false) },
                warm: { warmed.set() },
                meetings: FakeMeetings(notesSaved: notesSaved)
            )
            check("server starts", EngineSocket.start(at: url, services: services))
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let dirAttrs = try? FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
            check("socket is owner-only (0600)", (attrs?[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            check("folder is owner-only (0700)", (dirAttrs?[.posixPermissions] as? NSNumber)?.intValue == 0o700)

            func lines(_ payload: String) -> [[String: Any]] {
                Self.roundTrip(url: url, payload: payload).compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            }
            func ask(_ payload: String) -> [String: Any]? { lines(payload).first }

            let status = ask(#"{"op":"status"}"#)
            check("status reports the model", status?["ok"] as? Bool == true && status?["model"] as? String == "test-model" && status?["downloaded"] as? Bool == true)
            let gen = ask(#"{"op":"generate","system":"sys","user":"hello \#(secret)","max_tokens":50}"#)
            check("generate returns the text", (gen?["text"] as? String) == "echo(3,\(6 + secret.count),50):HELLO \(secret)")
            check("max_tokens is clamped to 800", (ask(#"{"op":"generate","user":"x","max_tokens":999999}"#)?["text"] as? String)?.hasPrefix("echo(0,1,800)") == true)
            check("generator failure is reported, not a crash", ask(#"{"op":"generate","user":"explode"}"#)?["ok"] as? Bool == false)
            check("warm returns at once and triggers the warmer", ask(#"{"op":"warm"}"#)?["ok"] as? Bool == true && warmed.value)

            // streaming
            let stream = lines(#"{"op":"generate_stream","user":"one two three"}"#)
            let tokens = stream.filter { $0["event"] as? String == "token" }.compactMap { $0["text"] as? String }
            check("a stream sends each piece as its own line", tokens == ["one ", "two ", "three "])
            check("a stream ends with done and a duration", stream.last?["event"] as? String == "done" && stream.last?["ms"] is Int)
            let broken = lines(#"{"op":"generate_stream","user":"explode"}"#)
            check("a stream that fails ends with an error event", broken.last?["event"] as? String == "error")
            check("a stream needs a prompt", ask(#"{"op":"generate_stream"}"#)?["event"] as? String == "error")

            // meetings
            let id = "11111111-2222-3333-4444-555555555555"
            let list = ask(#"{"op":"meetings.list"}"#)
            check("meetings.list returns the meetings", (list?["meetings"] as? [[String: Any]])?.first?["title"] as? String == "Design sync")
            let live = (ask(#"{"op":"meetings.live"}"#)?["live"] as? [String: Any])
            check("meetings.live reports the recording with its latest captions", live?["active"] as? Bool == true && (live?["rows"] as? [[String: Any]])?.count == 2 && (live?["rows"] as? [[String: Any]])?.last?["partial"] as? Bool == true)
            let got = ask(#"{"op":"meetings.get","id":"\#(id)"}"#)
            check("meetings.get returns one meeting with its segments", ((got?["meeting"] as? [String: Any])?["segments"] as? [Any])?.count == 1)
            check("meetings.get on an unknown id says so", ask(#"{"op":"meetings.get","id":"\#(UUID().uuidString)"}"#)?["ok"] as? Bool == false)
            check("meetings.get rejects a bad id", ask(#"{"op":"meetings.get","id":"not-a-uuid"}"#)?["ok"] as? Bool == false)
            check("meetings.notes_save saves", ask(#"{"op":"meetings.notes_save","id":"\#(id)","text":"my notes"}"#)?["ok"] as? Bool == true && notesSaved.value)
            let gennotes = lines(#"{"op":"meetings.notes_generate","id":"\#(id)","kind":"executive"}"#)
            check("notes generation reports progress then the result", gennotes.filter { $0["event"] as? String == "progress" }.count == 2 && gennotes.last?["event"] as? String == "done" && gennotes.last?["text"] as? String == "notes for executive")
            check("auto notes can say they were not needed", lines(#"{"op":"meetings.notes_generate","id":"\#(id)","auto":true}"#).last?["event"] as? String == "skipped")
            check("notes generation for a missing meeting ends with an error event", lines(#"{"op":"meetings.notes_generate","id":"\#(UUID().uuidString)"}"#).last?["event"] as? String == "error")

            // robustness
            check("garbage is rejected", ask("not json")?["ok"] as? Bool == false)
            check("unknown op is rejected", ask(#"{"op":"rm -rf"}"#)?["ok"] as? Bool == false)
            check("missing user is rejected", ask(#"{"op":"generate"}"#)?["ok"] as? Bool == false)
            let big = ask(#"{"op":"generate","user":"\#(String(repeating: "a", count: 1_100_000))"}"#)
            check("oversized request is rejected", big == nil || big?["ok"] as? Bool == false)
            // a listener that leaves mid-stream must not crash or wedge the server
            _ = Self.roundTrip(url: url, payload: #"{"op":"generate_stream","user":"\#(String(repeating: "word ", count: 400))"}"#, stopAfterFirstLine: true)
            check("still serving after a listener left mid-stream and after bad requests", ask(#"{"op":"status"}"#)?["ok"] as? Bool == true)
            EngineSocket.stop(removing: url)
            check("stop removes the socket", !FileManager.default.fileExists(atPath: url.path))
            try? FileManager.default.removeItem(at: base)
            print(failures == 0 ? "ENGINE SOCKET AUTOTEST ALL PASSED" : "ENGINE SOCKET AUTOTEST \(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    /// Minimal blocking client, the same thing myOS does from Rust. Returns every line the server sent.
    static func roundTrip(url: URL, payload: String, stopAfterFirstLine: Bool = false) -> [Data] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(url.path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return [] }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { return [] }
        let out = Array((payload + "\n").utf8)
        var sent = 0
        while sent < out.count {
            let n = out.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: sent), out.count - sent) }
            if n <= 0 { break }
            sent += n
        }
        var pending = Data()
        var result: [Data] = []
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            pending.append(buffer, count: n)
            while let newline = pending.firstIndex(of: 0x0A) {
                result.append(pending.prefix(upTo: newline))
                pending = pending.suffix(from: pending.index(after: newline))
                if stopAfterFirstLine { return result }
            }
        }
        if !pending.isEmpty { result.append(pending) }
        return result
    }
}
