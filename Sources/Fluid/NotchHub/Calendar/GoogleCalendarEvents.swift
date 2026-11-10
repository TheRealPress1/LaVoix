import Foundation

/// Meetings that already exist in a Google account's calendar: finding one (its Google id, its guests and Meet link), inviting more people, and deleting it.
/// The Mac's Calendar can do none of these for guests (EventKit has no way to add one), so the notch asks Google, with the same short-lived token the
/// new-event form uses (see `GoogleTokenVault`). Everything here works on the account's primary calendar, which is the calendar that token's permission
/// (`calendar.events`) reaches without a list of calendars.

nonisolated struct GoogleAttendee: Equatable {
    var email: String
    var name: String = ""
    /// Google's word: needsAction, accepted, declined or tentative.
    var status: String = "needsAction"
    var isOrganizer = false
    var isMe = false
    var optional = false
    /// A room or other resource rather than a person.
    var isResource = false

    var display: String { self.name.isEmpty || self.name.lowercased() == self.email.lowercased() ? self.email : self.name }
}

nonisolated struct GoogleEventDetails: Equatable {
    var id: String
    var title: String
    var start: Date?
    var attendees: [GoogleAttendee]
    var meetLink: String?
    var htmlLink: String?
    /// This account made the meeting (or is its organizer).
    var isOrganizer: Bool
    /// Google lets guests invite others unless the organizer switched it off.
    var guestsCanInvite: Bool
    /// The first of a repeating meeting (the whole series). The notch works on one occurrence, never on this.
    var isSeries = false

    /// Whether this account may add people: the organizer always may; a guest only when the organizer allows it.
    var canInviteOthers: Bool { self.isOrganizer || self.guestsCanInvite }
}

nonisolated extension GoogleCalendarClient {
    static let eventsBase = "https://www.googleapis.com/calendar/v3/calendars/primary/events"

    // MARK: - Addresses

    /// Percent-encodes one query value so an address like `a+b@x.com` or an id with `_` reaches Google unchanged (`+` must not become a space).
    static func encoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~@")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func utc(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// The meeting with this iCalendar id (the id the Mac's Calendar keeps for a Google meeting).
    static func findURL(iCalUID: String) -> URL? {
        URL(string: "\(self.eventsBase)?iCalUID=\(self.encoded(iCalUID))&maxResults=5&showDeleted=false")
    }

    /// Every meeting that starts in a short window, one entry per occurrence of a repeating meeting.
    static func windowURL(start: Date, end: Date) -> URL? {
        URL(string: "\(self.eventsBase)?timeMin=\(self.encoded(self.utc(start)))&timeMax=\(self.encoded(self.utc(end)))&singleEvents=true&orderBy=startTime&maxResults=50&showDeleted=false")
    }

    /// One meeting by its Google id. `sendUpdates=all` makes Google tell the guests about a change or a cancellation.
    static func eventURL(id: String, query: String = "") -> URL? {
        URL(string: "\(self.eventsBase)/\(self.encoded(id))" + (query.isEmpty ? "" : "?\(query)"))
    }

    // MARK: - Reading

    private static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    static func details(from item: [String: Any]) -> GoogleEventDetails? {
        guard let id = item["id"] as? String, (item["status"] as? String) != "cancelled" else { return nil }
        let organizer = item["organizer"] as? [String: Any]
        let attendees: [GoogleAttendee] = (item["attendees"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let email = (raw["email"] as? String)?.lowercased(), !email.isEmpty else { return nil }
            return GoogleAttendee(
                email: email, name: raw["displayName"] as? String ?? "", status: raw["responseStatus"] as? String ?? "needsAction",
                isOrganizer: raw["organizer"] as? Bool ?? false, isMe: raw["self"] as? Bool ?? false,
                optional: raw["optional"] as? Bool ?? false, isResource: raw["resource"] as? Bool ?? false
            )
        }
        var meet = item["hangoutLink"] as? String
        if meet == nil, let entries = (item["conferenceData"] as? [String: Any])?["entryPoints"] as? [[String: Any]] {
            meet = entries.first { ($0["entryPointType"] as? String) == "video" }?["uri"] as? String
        }
        return GoogleEventDetails(
            id: id, title: item["summary"] as? String ?? "",
            start: self.date((item["start"] as? [String: Any])?["dateTime"] as? String),
            attendees: attendees, meetLink: meet, htmlLink: item["htmlLink"] as? String,
            // With no organizer block Google means the account's own meeting; `self` is true when the organizer is this account.
            isOrganizer: organizer == nil || (organizer?["self"] as? Bool ?? false),
            guestsCanInvite: item["guestsCanInviteOthers"] as? Bool ?? true,
            isSeries: item["recurrence"] != nil
        )
    }

    /// An `events.list` answer: the meetings in it, or why not.
    static func parseList(status: Int, data: Data) -> Result<[GoogleEventDetails], GoogleCalendarFailure> {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else { return .failure(self.failure(status: status, object: object)) }
        return .success((object["items"] as? [[String: Any]] ?? []).compactMap(self.details(from:)))
    }

    /// An `events.get` or `events.patch` answer: the one meeting, or why not.
    static func parseEvent(status: Int, data: Data) -> Result<GoogleEventDetails, GoogleCalendarFailure> {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else { return .failure(self.failure(status: status, object: object)) }
        guard let found = self.details(from: object) else { return .failure(GoogleCalendarFailure(message: "Google can no longer find that meeting.")) }
        return .success(found)
    }

    /// The meeting in a list that is the one the notch shows: same title (any case) and the same start, to the minute.
    static func match(_ events: [GoogleEventDetails], title: String, start: Date) -> GoogleEventDetails? {
        // The notch calls a meeting with no title "Untitled".
        func name(_ text: String) -> String {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return clean.isEmpty ? "untitled" : clean
        }
        let wanted = name(title)
        return events.first { event in
            guard let when = event.start else { return false }
            return abs(when.timeIntervalSince(start)) < 60 && name(event.title) == wanted
        }
    }

    // MARK: - Changing

    /// What an update sends for the guest list. Google replaces the whole list, so everyone already invited is sent again with the answer they gave.
    static func guestListBody(_ attendees: [GoogleAttendee]) -> [String: Any] {
        ["attendees": attendees.map { guest -> [String: Any] in
            var entry: [String: Any] = ["email": guest.email]
            if !guest.name.isEmpty { entry["displayName"] = guest.name }
            if guest.status != "needsAction" { entry["responseStatus"] = guest.status }
            if guest.optional { entry["optional"] = true }
            if guest.isResource { entry["resource"] = true }
            return entry
        }]
    }

    /// The guest list with `new` people added (nobody twice, by address).
    static func adding(_ new: [GoogleAttendee], to existing: [GoogleAttendee]) -> [GoogleAttendee] {
        var seen = Set(existing.map { $0.email.lowercased() })
        var out = existing
        for guest in new where seen.insert(guest.email.lowercased()).inserted { out.append(guest) }
        return out
    }

    // MARK: - Asking Google

    private static func send(_ url: URL?, method: String, body: [String: Any]? = nil, token: String, session: URLSession) async -> Result<(Int, Data), GoogleCalendarFailure> {
        guard let url else { return .failure(GoogleCalendarFailure(message: "Bad Google address.")) }
        var http = URLRequest(url: url, timeoutInterval: 30)
        http.httpMethod = method
        http.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return .failure(GoogleCalendarFailure(message: "Could not prepare the change.")) }
            http.httpBody = payload
        }
        do {
            let (data, response) = try await session.data(for: http)
            return .success(((response as? HTTPURLResponse)?.statusCode ?? 0, data))
        } catch {
            return .failure(GoogleCalendarFailure(message: "Could not reach Google: \(error.localizedDescription)"))
        }
    }

    /// Google's record of a meeting the notch shows: looked up by the Google id when it is known, else by the iCalendar id the Mac keeps, else by title and
    /// start time. nil means Google has no such meeting in the primary calendar (a calendar of another account, a shared calendar, a subscribed one).
    static func find(id: String?, iCalUID: String?, title: String, start: Date, end: Date, token: String, session: URLSession = .shared) async -> Result<GoogleEventDetails?, GoogleCalendarFailure> {
        if let id {
            switch await self.send(self.eventURL(id: id), method: "GET", token: token, session: session) {
            case let .failure(failure): return .failure(failure)
            case let .success((status, data)):
                switch self.parseEvent(status: status, data: data) {
                case let .success(found): if !found.isSeries { return .success(found) }
                case let .failure(failure): if status != 404 && status != 410 { return .failure(failure) }
                }
            }
        }
        if let iCalUID, !iCalUID.isEmpty {
            switch await self.send(self.findURL(iCalUID: iCalUID), method: "GET", token: token, session: session) {
            case let .failure(failure): return .failure(failure)
            case let .success((status, data)):
                switch self.parseList(status: status, data: data) {
                case let .failure(failure): return .failure(failure)
                // A repeating meeting comes back as its whole series; the notch changes one occurrence, which the time window below finds.
                case let .success(found): if let single = found.first(where: { !$0.isSeries }) { return .success(single) }
                }
            }
        }
        switch await self.send(self.windowURL(start: start.addingTimeInterval(-120), end: end.addingTimeInterval(120)), method: "GET", token: token, session: session) {
        case let .failure(failure): return .failure(failure)
        case let .success((status, data)):
            switch self.parseList(status: status, data: data) {
            case let .failure(failure): return .failure(failure)
            case let .success(found): return .success(self.match(found, title: title, start: start))
            }
        }
    }

    /// Invites more people: Google sends each of them the invitation.
    static func addGuests(_ new: [GoogleAttendee], to event: GoogleEventDetails, token: String, session: URLSession = .shared) async -> Result<GoogleEventDetails, GoogleCalendarFailure> {
        let everyone = self.adding(new, to: event.attendees)
        switch await self.send(self.eventURL(id: event.id, query: "sendUpdates=all&conferenceDataVersion=1"), method: "PATCH", body: self.guestListBody(everyone), token: token, session: session) {
        case let .failure(failure): return .failure(failure)
        case let .success((status, data)): return self.parseEvent(status: status, data: data)
        }
    }

    /// Deletes the meeting; the guests are told. A meeting Google no longer has counts as deleted.
    static func delete(id: String, token: String, session: URLSession = .shared) async -> Result<Void, GoogleCalendarFailure> {
        switch await self.send(self.eventURL(id: id, query: "sendUpdates=all"), method: "DELETE", token: token, session: session) {
        case let .failure(failure): return .failure(failure)
        case let .success((status, data)):
            if (200..<300).contains(status) || status == 404 || status == 410 { return .success(()) }
            return .failure(self.failure(status: status, object: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]))
        }
    }
}
