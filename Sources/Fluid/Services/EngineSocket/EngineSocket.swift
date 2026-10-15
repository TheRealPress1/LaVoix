import Darwin
import Foundation

/// Lets myOS use LaVoix's on-device model. A Unix socket in the owner-only folder `~/Library/Application Support/myOS/private/`
/// (the same place as the message store), NOT a TCP port: any process on the Mac can reach a port, only this user can reach
/// this file. One request per connection, one JSON line each way:
///   {"op":"status"}                                                  -> {"ok":true,"model":"...","downloaded":true,"loaded":false}
///   {"op":"warm"}                                                    -> {"ok":true}   (starts loading the model; returns at once)
///   {"op":"generate","system":"...","user":"...","max_tokens":400}   -> {"ok":true,"text":"...","ms":1234}
/// Errors come back as {"ok":false,"error":"..."}. The prompts can contain message text, so nothing in here logs them.
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

    /// What generating means; injected so the autotest never needs a model.
    typealias Generator = @Sendable (_ system: String, _ user: String, _ maxTokens: Int) async throws -> String
    typealias StatusProvider = @Sendable () async -> (model: String, downloaded: Bool, loaded: Bool)
    /// Starts loading the model without waiting for it (nil in the autotest).
    typealias Warmer = @Sendable () -> Void

    private static let lock = NSLock()
    /// One listener per socket path (the autotest serves a temp path while the app serves the real one).
    private nonisolated(unsafe) static var listeners: [String: Int32] = [:]

    static func startIfEnabled() {
        guard self.isEnabled, ProcessInfo.processInfo.environment["LAVOIX_ENGINE_SOCKET_AUTOTEST"] != "1" else { return }
        _ = self.start(at: self.defaultURL, generator: self.liveGenerator, status: self.liveStatus, warm: self.liveWarmer)
    }

    static let liveGenerator: Generator = { system, user, maxTokens in
        let modelID = LocalCleanupSettings.modelID
        guard LocalCleanupProvider.isDownloaded(modelID: modelID) else { throw EngineError.modelMissing }
        return try await LocalCleanupEngine.shared.generate(
            system: system, user: user, modelID: modelID, maxTokens: maxTokens, temperature: 0, cachesPrefix: false
        )
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

    enum EngineError: LocalizedError {
        case modelMissing
        var errorDescription: String? { "The on-device model is not downloaded yet. Open LaVoix, then AI Providers, to download it." }
    }

    /// Binds the socket and serves it on background queues. Returns false if it could not (path too long, folder not writable).
    @discardableResult
    static func start(at url: URL, generator: @escaping Generator, status: @escaping StatusProvider, warm: @escaping Warmer = {}) -> Bool {
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
                self.serve(client: client, generator: generator, status: status, warm: warm)
            }
        }
        return true
    }

    static func stop(removing url: URL = EngineSocket.defaultURL) {
        self.lock.lock(); defer { self.lock.unlock() }
        if let fd = self.listeners.removeValue(forKey: url.path) { close(fd) }
        unlink(url.path)
    }

    private static func serve(client: Int32, generator: @escaping Generator, status: @escaping StatusProvider, warm: @escaping Warmer) {
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 10, tv_usec: 0) // a client that goes quiet cannot hold a thread
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == geteuid() else { close(client); return }

        DispatchQueue.global(qos: .utility).async {
            let request = self.readLine(client)
            Task.detached {
                let reply = await self.respond(to: request, generator: generator, status: status, warm: warm)
                DispatchQueue.global(qos: .utility).async {
                    self.writeAll(client, reply + Data("\n".utf8))
                    close(client)
                }
            }
        }
    }

    /// Pure request -> response, so the protocol can be tested without sockets or a model.
    static func respond(to line: Data?, generator: Generator, status: StatusProvider, warm: Warmer = {}) async -> Data {
        func json(_ object: [String: Any]) -> Data {
            (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(#"{"ok":false,"error":"encode"}"#.utf8)
        }
        func fail(_ message: String) -> Data { json(["ok": false, "error": message]) }
        guard let line, !line.isEmpty else { return fail("empty request") }
        guard line.count <= self.maxRequestBytes else { return fail("request too large") }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let op = object["op"] as? String else {
            return fail("not a JSON object with an op")
        }
        switch op {
        case "status":
            let s = await status()
            return json(["ok": true, "model": s.model, "downloaded": s.downloaded, "loaded": s.loaded])
        case "warm":
            warm()
            return json(["ok": true])
        case "generate":
            guard let user = object["user"] as? String, !user.isEmpty else { return fail("missing user") }
            let system = object["system"] as? String ?? ""
            let maxTokens = min(max((object["max_tokens"] as? Int) ?? 400, 16), 800)
            let start = Date()
            do {
                let text = try await generator(system, user, maxTokens)
                return json(["ok": true, "text": text, "ms": Int(Date().timeIntervalSince(start) * 1000)])
            } catch {
                return fail((error as? LocalizedError)?.errorDescription ?? "generation failed")
            }
        default:
            return fail("unknown op")
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

    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }
}

// MARK: - Autotest

private final class WarmFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { self.lock.lock(); self.flag = true; self.lock.unlock() }
    var value: Bool { self.lock.lock(); defer { self.lock.unlock() }; return self.flag }
}

/// `LAVOIX_ENGINE_SOCKET_AUTOTEST=1` serves a fake generator on a temp socket and talks to it as a client.
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
            let warmed = WarmFlag()
            let started = EngineSocket.start(
                at: url,
                generator: { system, user, maxTokens in
                    if user.contains("explode") { throw NSError(domain: "t", code: 1) }
                    return "echo(\(system.count),\(user.count),\(maxTokens)):" + user.uppercased()
                },
                status: { ("test-model", true, false) },
                warm: { warmed.set() }
            )
            check("server starts", started)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let dirAttrs = try? FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
            check("socket is owner-only (0600)", (attrs?[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            check("folder is owner-only (0700)", (dirAttrs?[.posixPermissions] as? NSNumber)?.intValue == 0o700)

            func ask(_ payload: String) -> [String: Any]? {
                guard let reply = Self.roundTrip(url: url, payload: payload) else { return nil }
                return (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
            }
            let status = ask(#"{"op":"status"}"#)
            check("status reports the model", status?["ok"] as? Bool == true && status?["model"] as? String == "test-model" && status?["downloaded"] as? Bool == true)
            let gen = ask(#"{"op":"generate","system":"sys","user":"hello \#(secret)","max_tokens":50}"#)
            check("generate returns the text", (gen?["text"] as? String) == "echo(3,\(6 + secret.count),50):HELLO \(secret)")
            let clamped = ask(#"{"op":"generate","user":"x","max_tokens":999999}"#)
            check("max_tokens is clamped to 800", (clamped?["text"] as? String)?.hasPrefix("echo(0,1,800)") == true)
            check("generator failure is reported, not a crash", ask(#"{"op":"generate","user":"explode"}"#)?["ok"] as? Bool == false)
            check("warm returns at once and triggers the warmer", ask(#"{"op":"warm"}"#)?["ok"] as? Bool == true && warmed.value)
            check("garbage is rejected", ask("not json")?["ok"] as? Bool == false)
            check("unknown op is rejected", ask(#"{"op":"rm -rf"}"#)?["ok"] as? Bool == false)
            check("missing user is rejected", ask(#"{"op":"generate"}"#)?["ok"] as? Bool == false)
            let big = ask(#"{"op":"generate","user":"\#(String(repeating: "a", count: 1_100_000))"}"#)
            check("oversized request is rejected", big == nil || big?["ok"] as? Bool == false)
            check("still serving after bad requests", ask(#"{"op":"status"}"#)?["ok"] as? Bool == true)
            EngineSocket.stop(removing: url)
            check("stop removes the socket", !FileManager.default.fileExists(atPath: url.path))
            try? FileManager.default.removeItem(at: base)
            print(failures == 0 ? "ENGINE SOCKET AUTOTEST ALL PASSED" : "ENGINE SOCKET AUTOTEST \(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    /// Minimal blocking client, the same thing myOS does from Rust.
    static func roundTrip(url: URL, payload: String) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(url.path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { return nil }
        let out = Array((payload + "\n").utf8)
        var sent = 0
        while sent < out.count {
            let n = out.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: sent), out.count - sent) }
            if n <= 0 { break }
            sent += n
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
            if data.last == 0x0A { break }
        }
        return data.isEmpty ? nil : data
    }
}
