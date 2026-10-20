import CryptoKit
import Foundation
import Network
import Security

/// Bump (a map-for-friends app) through its MCP server, for myOS. MCP over HTTPS is plain JSON-RPC, so this is a small client, not an AI
/// call: the engine signs you in with Bump's OAuth (a browser page you approve, PKCE, no password handled here), keeps the tokens in the
/// Keychain, refreshes them itself, and calls Bump's tools on myOS's behalf. No operation sends a token back to myOS.
nonisolated protocol EngineBumpProviding: Sendable {
    /// {connected, pending?: true}
    func status() async -> [String: Any]
    /// Starts sign-in: {authorize_url}. Open it in the browser; a page on 127.0.0.1 catches the answer.
    func connectStart() async throws -> [String: Any]
    /// {status: "pending"|"connected"|"denied"|"expired"|"none"}
    func connectPoll() async throws -> [String: Any]
    /// Forgets the tokens on this Mac.
    func disconnect() async throws
    /// Who you are and where you are, from Bump: {first_name?, home_country?, current_city?, is_traveling?, location_shared?}
    func me() async throws -> [String: Any]
    /// The names of the tools Bump offers.
    func tools() async throws -> [String]
    /// Calls one Bump tool and returns what it answered (parsed JSON, or {"_text": …} when it answered in prose).
    func callTool(name: String, arguments: [String: Any]) async throws -> [String: Any]
}

nonisolated enum EngineBumpError: LocalizedError, Equatable {
    case notConnected, reconnectNeeded, noSignIn, tool(String), server(String), network
    var errorDescription: String? {
        switch self {
        case .notConnected: "Bump isn't connected yet."
        case .reconnectNeeded: "Bump no longer accepts this sign-in; connect again."
        case .noSignIn: "There is no sign-in in progress."
        case let .tool(m): m
        case let .server(m): m
        case .network: "Couldn't reach Bump."
        }
    }
}

nonisolated struct BumpTokens: Codable, Equatable, Sendable {
    var clientId: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
}

nonisolated enum BumpRules {
    /// What myOS may ask Bump through the engine: reads only. `bump_watch` (creates reminders), image generation and stickers are left out.
    static let readOnlyTools: Set<String> = [
        "bump_friends_footprint_explored", "bump_friends_footprint_zone_status", "bump_friends_friend_info", "bump_friends_friends",
        "bump_friends_gatherings", "bump_friends_live_status", "bump_friends_map_stories", "bump_friends_place_recommendations",
        "bump_friends_place_search", "bump_friends_place_visits", "bump_friends_places", "bump_friends_routines", "bump_friends_sleep",
        "bump_friends_time_together",
    ]
}

/// A one-shot web server on 127.0.0.1 that catches the browser's redirect after you approve the sign-in.
nonisolated final class BumpLoopbackReceiver: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private var result: [String: String]?
    private(set) var port: UInt16 = 0

    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global(qos: .userInitiated))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let line = text.components(separatedBy: "\r\n").first ?? ""
                let parts = line.split(separator: " ")
                if parts.count >= 2, parts[0] == "GET", let comps = URLComponents(string: "http://127.0.0.1" + String(parts[1])), comps.path == "/callback" {
                    var q: [String: String] = [:]
                    for item in comps.queryItems ?? [] { if let v = item.value { q[item.name] = v } }
                    self?.lock.lock(); self?.result = q; self?.lock.unlock()
                }
                let body = "<html><body style=\"font-family:-apple-system,sans-serif;padding:40px\">Done. You can close this tab and go back to myOS.</body></html>"
                let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.take() { continuation.resume() }
                case let .failed(error):
                    if once.take() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
        self.port = listener.port?.rawValue ?? 0
    }

    var received: [String: String]? { self.lock.lock(); defer { self.lock.unlock() }; return self.result }
    func stop() { self.listener?.cancel(); self.listener = nil }
}

private nonisolated final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool { self.lock.lock(); defer { self.lock.unlock() }; if self.taken { return false }; self.taken = true; return true }
}

/// A generic Keychain slot for one secret string.
nonisolated struct KeychainSecret: BookshelfCredentialStoring {
    let service: String
    let account: String
    private var base: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: self.service, kSecAttrAccount as String: self.account] }

    func load() -> String? {
        var query = self.base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ token: String) throws {
        self.delete()
        var item = self.base
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw EngineBumpError.server("macOS wouldn't store the sign-in in the Keychain.") }
    }

    func delete() { SecItemDelete(self.base as CFDictionary) }
}

actor LiveEngineBump: EngineBumpProviding {
    private let base: URL
    private let session: URLSession
    private let store: any BookshelfCredentialStoring
    private let openURL: @Sendable (URL) -> Void
    private var pending: (clientId: String, verifier: String, state: String, redirect: String, receiver: BumpLoopbackReceiver, started: Date)?
    private var mcpSession: String?
    private var initialized = false

    init(base: URL = URL(string: "https://mcp-beta.amo.co")!, session: URLSession = .shared,
         store: any BookshelfCredentialStoring = KeychainSecret(service: "com.myos.engine.bump", account: "tokens"),
         openURL: @escaping @Sendable (URL) -> Void = { _ in }) {
        self.base = base
        self.session = session
        self.store = store
        self.openURL = openURL
    }

    // MARK: - Sign-in

    func status() async -> [String: Any] {
        var out: [String: Any] = ["connected": self.tokens() != nil]
        if self.pending != nil { out["pending"] = true }
        return out
    }

    func connectStart() async throws -> [String: Any] {
        self.pending?.receiver.stop()
        let receiver = BumpLoopbackReceiver()
        do { try await receiver.start() } catch { throw EngineBumpError.server("Couldn't open a local page to receive the sign-in.") }
        let redirect = "http://127.0.0.1:\(receiver.port)/callback"
        let reg = try await self.json("POST", "/oauth/register", body: [
            "client_name": "myOS", "redirect_uris": [redirect], "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"], "token_endpoint_auth_method": "none", "scope": "mcp",
        ], bearer: nil)
        guard let clientId = reg["client_id"] as? String else { receiver.stop(); throw EngineBumpError.server("Bump didn't accept the sign-in request.") }
        let verifier = Self.randomURLSafe(48)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafe(12)
        var comps = URLComponents(url: self.base.appendingPathComponent("oauth/authorize"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: clientId), .init(name: "redirect_uri", value: redirect),
            .init(name: "scope", value: "mcp"), .init(name: "state", value: state), .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "resource", value: self.base.appendingPathComponent("mcp").absoluteString),
        ]
        self.pending = (clientId, verifier, state, redirect, receiver, Date())
        guard let url = comps.url else { receiver.stop(); throw EngineBumpError.network }
        self.openURL(url)
        return ["authorize_url": url.absoluteString]
    }

    func connectPoll() async throws -> [String: Any] {
        guard let p = self.pending else { return ["status": "none"] }
        if Date().timeIntervalSince(p.started) > 600 { p.receiver.stop(); self.pending = nil; return ["status": "expired"] }
        guard let answer = p.receiver.received else { return ["status": "pending"] }
        p.receiver.stop()
        self.pending = nil
        guard answer["state"] == p.state, let code = answer["code"] else { return ["status": "denied"] }
        let tok = try await self.json("POST", "/oauth/token", form: [
            "grant_type": "authorization_code", "code": code, "redirect_uri": p.redirect, "client_id": p.clientId, "code_verifier": p.verifier,
        ])
        try self.save(from: tok, clientId: p.clientId, keepingRefresh: nil)
        self.mcpSession = nil
        self.initialized = false
        return ["status": "connected"]
    }

    func disconnect() async throws {
        self.pending?.receiver.stop()
        self.pending = nil
        self.store.delete()
        self.mcpSession = nil
        self.initialized = false
    }

    // MARK: - Tokens

    private func tokens() -> BumpTokens? {
        guard let raw = self.store.load(), let data = raw.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(BumpTokens.self, from: data)
    }

    private func save(from tok: [String: Any], clientId: String, keepingRefresh: String?) throws {
        guard let access = tok["access_token"] as? String else { throw EngineBumpError.server("Bump sent no access token.") }
        let lifetime = (tok["expires_in"] as? Double) ?? 3600
        let value = BumpTokens(clientId: clientId, accessToken: access, refreshToken: (tok["refresh_token"] as? String) ?? keepingRefresh, expiresAt: Date().addingTimeInterval(lifetime))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { throw EngineBumpError.server("Couldn't keep the sign-in.") }
        try self.store.save(text)
    }

    /// A token good for at least the next minute, refreshed when needed.
    private func accessToken() async throws -> String {
        guard let t = self.tokens() else { throw EngineBumpError.notConnected }
        if t.expiresAt.timeIntervalSinceNow > 60 { return t.accessToken }
        return try await self.refresh(t)
    }

    private func refresh(_ t: BumpTokens) async throws -> String {
        guard let refresh = t.refreshToken else { self.store.delete(); throw EngineBumpError.reconnectNeeded }
        do {
            let tok = try await self.json("POST", "/oauth/token", form: ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": t.clientId])
            try self.save(from: tok, clientId: t.clientId, keepingRefresh: refresh)
        } catch EngineBumpError.network {
            throw EngineBumpError.network
        } catch {
            self.store.delete()
            throw EngineBumpError.reconnectNeeded
        }
        guard let fresh = self.tokens() else { throw EngineBumpError.reconnectNeeded }
        return fresh.accessToken
    }

    // MARK: - MCP

    func tools() async throws -> [String] {
        let r = try await self.rpc("tools/list", params: [:])
        return ((r["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        let r = try await self.rpc("tools/call", params: ["name": name, "arguments": arguments])
        if let structured = r["structuredContent"] as? [String: Any], r["isError"] as? Bool != true { return structured }
        let text = ((r["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        if r["isError"] as? Bool == true { throw EngineBumpError.tool(text.isEmpty ? "Bump's tool failed." : text) }
        if let data = text.data(using: .utf8), let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return obj }
        return ["_text": text]
    }

    func me() async throws -> [String: Any] {
        let r = try await self.callTool(name: "bump_friends_friend_info", arguments: [:])
        var out: [String: Any] = [:]
        if let p = r["person"] as? [String: Any], let f = p["first_name"] as? String { out["first_name"] = f }
        if let v = r["home_country_name"] as? String { out["home_country"] = v }
        if let v = r["current_city"] as? String { out["current_city"] = v }
        if let v = r["is_traveling"] as? Bool { out["is_traveling"] = v }
        if let v = r["location_shared"] as? Bool { out["location_shared"] = v }
        return out
    }

    private func ensureInitialized(token: String) async throws {
        if self.initialized { return }
        _ = try await self.post(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "myOS", "version": "1"],
        ]], token: token, expectResult: true)
        _ = try await self.post(["jsonrpc": "2.0", "method": "notifications/initialized"], token: token, expectResult: false)
        self.initialized = true
    }

    private func rpc(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        var token = try await self.accessToken()
        for attempt in 0..<2 {
            do {
                try await self.ensureInitialized(token: token)
                return try await self.post(["jsonrpc": "2.0", "id": 2, "method": method, "params": params], token: token, expectResult: true)
            } catch EngineBumpError.reconnectNeeded where attempt == 0 {
                // The server said 401: the token may have been revoked or expired early. Refresh once and retry.
                guard let t = self.tokens() else { throw EngineBumpError.reconnectNeeded }
                token = try await self.refresh(t)
                self.initialized = false
                self.mcpSession = nil
            } catch EngineBumpError.server(let m) where m == "session" && attempt == 0 {
                self.initialized = false
                self.mcpSession = nil
            }
        }
        throw EngineBumpError.network
    }

    private func post(_ message: [String: Any], token: String, expectResult: Bool) async throws -> [String: Any] {
        var request = URLRequest(url: self.base.appendingPathComponent("mcp"))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let id = self.mcpSession { request.setValue(id, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: message)
        let data: Data, response: URLResponse
        do { (data, response) = try await self.session.data(for: request) } catch { throw EngineBumpError.network }
        guard let http = response as? HTTPURLResponse else { throw EngineBumpError.network }
        if http.statusCode == 401 { throw EngineBumpError.reconnectNeeded }
        if http.statusCode == 404, self.mcpSession != nil { throw EngineBumpError.server("session") }
        guard (200..<300).contains(http.statusCode) else { throw EngineBumpError.server("Bump answered with an error (\(http.statusCode)).") }
        if let id = http.value(forHTTPHeaderField: "Mcp-Session-Id") { self.mcpSession = id }
        guard expectResult else { return [:] }
        guard let reply = Self.parseReply(data), reply["error"] == nil else {
            let message = ((Self.parseReply(data)?["error"] as? [String: Any])?["message"] as? String) ?? "Bump sent an unreadable reply."
            throw EngineBumpError.server(message)
        }
        return (reply["result"] as? [String: Any]) ?? [:]
    }

    /// A reply is plain JSON, or server-sent events carrying one JSON message each.
    nonisolated static func parseReply(_ data: Data) -> [String: Any]? {
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return obj }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\n") where line.hasPrefix("data:") {
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, let d = payload.data(using: .utf8), let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  obj["result"] != nil || obj["error"] != nil else { continue }
            return obj
        }
        return nil
    }

    // MARK: - HTTP helpers

    private func json(_ method: String, _ path: String, body: [String: Any]? = nil, form: [String: String]? = nil, bearer: String? = nil) async throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: self.base)?.absoluteURL else { throw EngineBumpError.network }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var c = URLComponents()
            c.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = c.percentEncodedQuery?.data(using: .utf8)
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await self.session.data(for: request) } catch { throw EngineBumpError.network }
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw EngineBumpError.server((obj["error_description"] as? String) ?? (obj["error"] as? String) ?? "Bump answered with an error (\(http.statusCode)).")
        }
        return obj
    }

    nonisolated static func randomURLSafe(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return self.base64URL(Data(b))
    }

    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
