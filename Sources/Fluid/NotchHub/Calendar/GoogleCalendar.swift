import Foundation

/// Creating a meeting in a Google account's calendar: a real Google Meet link, and Google sends the invitations. The Mac's Calendar cannot do
/// either (EventKit has no way to add guests and no Meet), so the notch talks to Google's Calendar service for accounts that allowed it.
///
/// The sign-ins stay in myOS's Keychain. myOS hands the engine short-lived access tokens (`google.tokens`); they live in memory only.

/// The access tokens myOS handed over, by account address.
nonisolated final class GoogleTokenVault: @unchecked Sendable {
    static let shared = GoogleTokenVault()

    private let lock = NSLock()
    private var tokens: [String: (token: String, expires: Date)] = [:]

    /// Replaces everything held (an empty list forgets every token).
    func replace(with accounts: [(email: String, token: String, expires: Date)]) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.tokens = Dictionary(accounts.map { ($0.email.lowercased(), ($0.token, $0.expires)) }, uniquingKeysWith: { _, last in last })
    }

    /// A token for this address with at least a minute of life left.
    func token(for email: String, now: Date = Date()) -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let held = self.tokens[email.lowercased()], held.expires.timeIntervalSince(now) > 60 else { return nil }
        return held.token
    }

    func has(_ email: String, now: Date = Date()) -> Bool { self.token(for: email, now: now) != nil }

    /// The accounts in a `google.tokens` request: `{"accounts":[{"email","access_token","expires_at"}]}` (expiry in Unix seconds).
    static func accounts(in object: [String: Any]) -> [(email: String, token: String, expires: Date)]? {
        guard let list = object["accounts"] as? [[String: Any]] else { return nil }
        return list.compactMap { item in
            guard let email = item["email"] as? String, email.contains("@"), let token = item["access_token"] as? String, !token.isEmpty,
                  let expires = (item["expires_at"] as? NSNumber)?.doubleValue else { return nil }
            return (email, token, Date(timeIntervalSince1970: expires))
        }
    }
}

nonisolated struct GoogleEventRequest: Equatable {
    var title: String
    var start: Date
    var end: Date
    var guests: [String]
    var withMeet: Bool
    var timeZone: TimeZone = .current
}

nonisolated struct GoogleEventResult: Equatable {
    let id: String
    let htmlLink: String?
    /// The Google Meet link, when one was made.
    let meetLink: String?
}

nonisolated struct GoogleCalendarFailure: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { self.message }
}

nonisolated enum GoogleCalendarClient {
    static let endpoint = "https://www.googleapis.com/calendar/v3/calendars/primary/events?conferenceDataVersion=1&sendUpdates=all"

    private static func time(_ date: Date, in zone: TimeZone) -> [String: String] {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = zone
        formatter.formatOptions = [.withInternetDateTime]
        return ["dateTime": formatter.string(from: date), "timeZone": zone.identifier]
    }

    /// The event as Google's `events.insert` takes it. Guests are invited by Google (`sendUpdates=all` in the address); a Meet link is asked for
    /// with a fresh request id.
    static func body(for request: GoogleEventRequest, requestID: String = UUID().uuidString) -> [String: Any] {
        var body: [String: Any] = [
            "summary": request.title,
            "start": self.time(request.start, in: request.timeZone),
            "end": self.time(request.end, in: request.timeZone),
        ]
        if !request.guests.isEmpty { body["attendees"] = request.guests.map { ["email": $0] } }
        if request.withMeet {
            body["conferenceData"] = ["createRequest": ["requestId": requestID, "conferenceSolutionKey": ["type": "hangoutsMeet"]]]
        }
        return body
    }

    /// Google's answer in words: the new event, or why not (a refused permission says where to give it).
    static func parse(status: Int, data: Data) -> Result<GoogleEventResult, GoogleCalendarFailure> {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if (200..<300).contains(status), let id = object["id"] as? String {
            var meet = object["hangoutLink"] as? String
            if meet == nil, let entries = (object["conferenceData"] as? [String: Any])?["entryPoints"] as? [[String: Any]] {
                meet = entries.first { ($0["entryPointType"] as? String) == "video" }?["uri"] as? String
            }
            return .success(GoogleEventResult(id: id, htmlLink: object["htmlLink"] as? String, meetLink: meet))
        }
        let error = object["error"] as? [String: Any]
        let text = (error?["message"] as? String) ?? ""
        switch status {
        case 401:
            return .failure(GoogleCalendarFailure(message: "Google's sign-in for this account ran out. Open myOS, Mail, and press Allow calendar events."))
        case 403 where text.localizedCaseInsensitiveContains("insufficient") || text.localizedCaseInsensitiveContains("scope"):
            return .failure(GoogleCalendarFailure(message: "This Google account has not allowed calendar events yet. Open myOS, Mail, and press Allow calendar events."))
        case 403 where text.localizedCaseInsensitiveContains("not been used") || text.localizedCaseInsensitiveContains("disabled"):
            return .failure(GoogleCalendarFailure(message: "The Google Calendar API is not switched on in your Google Cloud project."))
        default:
            return .failure(GoogleCalendarFailure(message: text.isEmpty ? "Google did not accept the event (error \(status))." : text))
        }
    }

    static func create(_ request: GoogleEventRequest, token: String, session: URLSession = .shared) async -> Result<GoogleEventResult, GoogleCalendarFailure> {
        guard let url = URL(string: self.endpoint) else { return .failure(GoogleCalendarFailure(message: "Bad Google address.")) }
        var http = URLRequest(url: url, timeoutInterval: 30)
        http.httpMethod = "POST"
        http.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let payload = try? JSONSerialization.data(withJSONObject: self.body(for: request)) else {
            return .failure(GoogleCalendarFailure(message: "Could not prepare the event."))
        }
        http.httpBody = payload
        do {
            let (data, response) = try await session.data(for: http)
            return self.parse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
        } catch {
            return .failure(GoogleCalendarFailure(message: "Could not reach Google: \(error.localizedDescription)"))
        }
    }
}
