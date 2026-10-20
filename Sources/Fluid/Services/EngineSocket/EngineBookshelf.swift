import Foundation
import Security

/// Bookshelf (bookshelf.music, the separate music-rating product) as a paired device of your account, for myOS.
/// The device token is write-only from myOS's point of view: it lives in the Keychain, and no operation ever sends it back. Wire shapes
/// follow Bookshelf's own Mac app (`/api/devices/pairing/*`, `/api/listening/history/`); every path keeps its trailing slash, because the
/// site redirects bare paths. Plain dictionaries so the socket sends them as JSON; the autotest uses a fake.
nonisolated protocol EngineBookshelfProviding: Sendable {
    /// {connected, site, device_name?, pending?: {user_code, verification_url}}
    func status() async -> [String: Any]
    /// Begins pairing: {user_code, verification_url, expires_at?}. The member approves the code in the browser.
    func pairStart(provider: String, deviceName: String) async throws -> [String: Any]
    /// {status: "pending"|"approved"|"expired"|"denied"|"none"}; on approval the token is stored and the account is connected.
    func pairPoll() async throws -> [String: Any]
    /// Forgets the token on this Mac (revoking the device on the site is done from the site's settings).
    func unpair() async throws
    /// [{id, date, title, artist, album, artwork_url?, score?, note?, played_at, editable}]
    func history(limit: Int) async throws -> [[String: Any]]
    /// Sets (or clears, with nil) the grade of a past listening row; returns the saved row.
    func rateHistory(id: String, score: Double?, note: String?) async throws -> [String: Any]
    /// What is playing as Bookshelf sees it: {connected, state, provider?, title?, artist?, album?, artwork_url?, can_rate, score?, note?, status}
    func now() async -> [String: Any]
    /// Grades (nil clears) the track playing now; returns what `now()` would say afterwards.
    func rateNow(score: Double?, note: String?) async throws -> [String: Any]
}

nonisolated enum EngineBookshelfError: LocalizedError, Equatable {
    case notConnected, noPairing, badScore, badProvider, badName, server(String), network
    var errorDescription: String? {
        switch self {
        case .notConnected: "Bookshelf isn't connected yet."
        case .noPairing: "There is no pairing in progress."
        case .badScore: "A grade is a number from 0 to 10."
        case .badProvider: "Bookshelf supports Spotify and Apple Music."
        case .badName: "That device name is not valid."
        case let .server(m): m
        case .network: "Couldn't reach Bookshelf."
        }
    }
}

nonisolated protocol BookshelfCredentialStoring: Sendable {
    func load() -> String?
    func save(_ token: String) throws
    func delete()
}

nonisolated struct KeychainBookshelfCredentials: BookshelfCredentialStoring {
    private let service = "com.myos.engine.bookshelf"
    private let account = "device-token"

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: self.service, kSecAttrAccount as String: self.account]
    }

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
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw EngineBookshelfError.server("macOS wouldn't store the token in the Keychain.") }
    }

    func delete() { SecItemDelete(self.base as CFDictionary) }
}

nonisolated enum BookshelfRules {
    static let providers: Set<String> = ["spotify", "apple_music"]

    static func deviceName(_ raw: String) throws -> String {
        let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.count <= 80, !n.contains("\n") else { throw EngineBookshelfError.badName }
        return n
    }

    /// Bookshelf grades are 0–10 with one decimal.
    static func score(_ raw: Double?) throws -> Double? {
        guard let raw else { return nil }
        guard raw.isFinite, raw >= 0, raw <= 10 else { throw EngineBookshelfError.badScore }
        return (raw * 10).rounded() / 10
    }

    /// One history event in the shape myOS reads. A missing field stays missing; nothing is invented.
    static func event(_ e: [String: Any]) -> [String: Any]? {
        guard let id = e["id"] as? String, let title = e["title"] as? String else { return nil }
        var out: [String: Any] = [
            "id": id, "title": title,
            "date": e["listeningDate"] as? String ?? "",
            "artist": e["albumArtist"] as? String ?? e["artist"] as? String ?? "",
            "album": e["album"] as? String ?? "",
            "played_at": e["lastPlayedAt"] as? String ?? "",
            "editable": e["isEditable"] as? Bool ?? false,
        ]
        if let a = e["artworkUrl"] as? String { out["artwork_url"] = a }
        if let s = e["score"] as? Double { out["score"] = s } else if let s = e["score"] as? Int { out["score"] = Double(s) }
        if let n = e["note"] as? String, !n.isEmpty { out["note"] = n }
        return out
    }
}

actor LiveEngineBookshelf: EngineBookshelfProviding {
    private let site: URL
    private let session: URLSession
    private let store: any BookshelfCredentialStoring
    private let capture: BookshelfCapture?
    private var pairing: (id: String, secret: String, userCode: String, url: String, tokenFromStart: String?, deviceName: String)?

    init(site: URL = URL(string: "https://bookshelf.music")!, session: URLSession = .shared,
         store: any BookshelfCredentialStoring = KeychainBookshelfCredentials(), capture: BookshelfCapture? = nil) {
        self.capture = capture
        self.site = site
        self.session = session
        self.store = store
    }

    func status() async -> [String: Any] {
        var out: [String: Any] = ["connected": self.store.load() != nil, "site": self.site.absoluteString]
        if let p = self.pairing { out["pending"] = ["user_code": p.userCode, "verification_url": p.url] }
        return out
    }

    func pairStart(provider: String, deviceName: String) async throws -> [String: Any] {
        guard BookshelfRules.providers.contains(provider) else { throw EngineBookshelfError.badProvider }
        let name = try BookshelfRules.deviceName(deviceName)
        let json = try await self.send("POST", "/api/devices/pairing/start/", body: ["deviceName": name, "provider": provider], token: nil)
        guard let id = json["pairingId"] as? String, let secret = json["pairingSecret"] as? String,
              let code = json["userCode"] as? String, let url = json["verificationUrl"] as? String else { throw EngineBookshelfError.server("Bookshelf sent an unexpected pairing reply.") }
        self.pairing = (id, secret, code, url, json["deviceToken"] as? String, name)
        var out: [String: Any] = ["user_code": code, "verification_url": url]
        if let e = json["expiresAt"] as? String { out["expires_at"] = e }
        return out
    }

    func pairPoll() async throws -> [String: Any] {
        guard let p = self.pairing else { return ["status": "none"] }
        let json = try await self.send("POST", "/api/devices/pairing/status/", body: ["pairingId": p.id, "pairingSecret": p.secret], token: nil)
        switch json["status"] as? String {
        case "approved":
            guard let token = (json["deviceToken"] as? String) ?? p.tokenFromStart, !token.isEmpty else { throw EngineBookshelfError.server("Bookshelf approved the pairing but sent no credential.") }
            try self.store.save(token)
            self.pairing = nil
            await MainActor.run { NotificationCenter.default.post(name: BookshelfCapture.credentialsChanged, object: nil) }
            return ["status": "approved"]
        case "expired": self.pairing = nil; return ["status": "expired"]
        case "denied": self.pairing = nil; return ["status": "denied"]
        default: return ["status": "pending"]
        }
    }

    func unpair() async throws {
        self.pairing = nil
        self.store.delete()
        await MainActor.run { NotificationCenter.default.post(name: BookshelfCapture.credentialsChanged, object: nil) }
    }

    func now() async -> [String: Any] {
        let connected = self.store.load() != nil
        return await MainActor.run {
            let n = (self.capture ?? BookshelfCapture.shared).now
            var out: [String: Any] = ["connected": connected, "state": n.state.rawValue, "can_rate": connected && n.canRate, "status": n.status]
            if let p = n.provider { out["provider"] = p.rawValue }
            if let v = n.title { out["title"] = v }
            if let v = n.artist { out["artist"] = v }
            if let v = n.album { out["album"] = v }
            if let v = n.artworkURL { out["artwork_url"] = v }
            if let v = n.score { out["score"] = v }
            if let v = n.note, !v.isEmpty { out["note"] = v }
            return out
        }
    }

    func rateNow(score: Double?, note: String?) async throws -> [String: Any] {
        let c = await MainActor.run { self.capture ?? BookshelfCapture.shared }
        try await c.rateNow(score: score, note: note)
        return await self.now()
    }

    func history(limit: Int) async throws -> [[String: Any]] {
        guard let token = self.store.load() else { throw EngineBookshelfError.notConnected }
        let json = try await self.send("GET", "/api/listening/history/?limit=\(min(max(limit, 1), 200))", body: nil, token: token)
        return (json["events"] as? [[String: Any]] ?? []).compactMap(BookshelfRules.event)
    }

    func rateHistory(id: String, score: Double?, note: String?) async throws -> [String: Any] {
        guard let token = self.store.load() else { throw EngineBookshelfError.notConnected }
        let checked = try BookshelfRules.score(score)
        var body: [String: Any] = ["dailyEventId": id, "score": checked.map { $0 as Any } ?? NSNull()]
        if let note { body["note"] = note }
        let json = try await self.send("POST", "/api/listening/history/", body: body, token: token)
        guard let event = (json["event"] as? [String: Any]).flatMap(BookshelfRules.event) else { throw EngineBookshelfError.server("Bookshelf sent an unexpected reply.") }
        return event
    }

    private func send(_ method: String, _ path: String, body: [String: Any]?, token: String?) async throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: self.site)?.absoluteURL else { throw EngineBookshelfError.network }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await self.session.data(for: request) } catch { throw EngineBookshelfError.network }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // A revoked or unknown credential is the one failure worth clearing local state for.
            if http.statusCode == 401, token != nil {
                self.store.delete()
                await MainActor.run { NotificationCenter.default.post(name: BookshelfCapture.credentialsChanged, object: nil) }
            }
            throw EngineBookshelfError.server(http.statusCode == 401 && token != nil
                ? "Bookshelf no longer accepts this device; pair again."
                : (json["error"] as? String ?? "Bookshelf answered with an error (\(http.statusCode))."))
        }
        return json
    }
}
