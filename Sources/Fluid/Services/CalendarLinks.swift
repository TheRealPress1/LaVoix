import CryptoKit
import EventKit
import Foundation

/// Links calendar events to the people myOS knows, without ever writing an email address: invitees are matched against
/// myOS's own database in memory and only opaque person ids (plus a count of unknown invitees) leave this file.
nonisolated enum CalendarLinks {
    struct Candidate: Equatable {
        let id: String            // same format as CalendarStore.Event.id
        let title: String
        let start: Date
        let end: Date
        let emails: [String]      // invitees other than you; in memory only
        let attendeeCount: Int
    }

    struct Item: Codable, Equatable {
        var external_id: String
        var title: String
        var start: String
        var end: String
        var person_ids: [String]
        var unknown_attendees: Int
    }

    static let rangeBefore: TimeInterval = 365 * 86400
    static let rangeAfter: TimeInterval = 90 * 86400
    static let lastHashKey = "CalendarLinksLastHash"

    // MARK: - Reading the calendar

    static func candidate(from event: EKEvent) -> Candidate? {
        guard !event.isAllDay, event.status != .canceled else { return nil }
        let attendees = event.attendees ?? []
        if attendees.first(where: \.isCurrentUser)?.participantStatus == .declined { return nil }
        let emails = attendees.filter { !$0.isCurrentUser }.compactMap { participant -> String? in
            let raw = participant.url.absoluteString
            return raw.lowercased().hasPrefix("mailto:") ? String(raw.dropFirst(7)).lowercased() : nil
        }
        guard !emails.isEmpty else { return nil }
        return Candidate(
            id: "\(event.eventIdentifier ?? event.title ?? "event")|\(event.startDate.timeIntervalSince1970)",
            title: (event.title?.isEmpty == false ? event.title : nil) ?? "Untitled",
            start: event.startDate, end: event.endDate, emails: emails, attendeeCount: attendees.count
        )
    }

    /// nil when Calendar access has not been granted (this never asks).
    static func fetch(start: Date, end: Date) -> [Candidate]? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let store = EKEventStore()
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
        return events.compactMap(candidate(from:))
    }

    // MARK: - Pure logic

    /// The id myOS sees for an event: a hash, because calendar ids can contain an `@` (Google's look like `uid@google.com`)
    /// and nothing that looks like an address should be written. Stable, so the same event is always the same id.
    static func externalID(for eventID: String) -> String {
        "cal:" + SHA256.hash(data: Data(eventID.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// The event a recording most plausibly belongs to: it overlaps at least half of the recording, or starts within
    /// 15 minutes of it; the largest overlap wins.
    static func bestOverlap(_ candidates: [Candidate], start: Date, end: Date) -> Candidate? {
        let length = max(1, end.timeIntervalSince(start))
        return candidates
            .map { c -> (Candidate, TimeInterval) in
                (c, max(0, min(end, c.end).timeIntervalSince(max(start, c.start))))
            }
            .filter { $0.1 / length >= 0.5 || abs($0.0.start.timeIntervalSince(start)) <= 15 * 60 }
            .max { $0.1 < $1.1 }?.0
    }

    /// Only events with at least one known invitee are worth a link.
    static func items(candidates: [Candidate], people: [String: KnownPerson]) -> [Item] {
        let iso = ISO8601DateFormatter()
        return candidates.compactMap { c in
            let known = Array(Set(c.emails.compactMap { people[$0]?.id })).sorted()
            guard !known.isEmpty else { return nil }
            return Item(
                external_id: externalID(for: c.id), title: c.title, start: iso.string(from: c.start), end: iso.string(from: c.end),
                person_ids: known, unknown_attendees: max(0, c.emails.count - known.count)
            )
        }.sorted { ($0.start, $0.external_id) < ($1.start, $1.external_id) }
    }

    // MARK: - Snapshot file

    private struct Snapshot: Codable {
        var schema = 1
        var source = "calendar"
        var generated_at: String
        var events: [Item]
    }

    static func contentHash(_ items: [Item]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: (try? encoder.encode(items)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }

    /// Writes `<data>/inbox/calendar/calendar-<UTC>.json` unless nothing changed. Each snapshot replaces the last one in myOS.
    @discardableResult
    static func write(items: [Item], dataDirectory: URL, defaults: UserDefaults = .standard, now: Date = Date()) throws -> URL? {
        let hash = contentHash(items)
        if defaults.string(forKey: lastHashKey) == hash { return nil }
        let directory = dataDirectory.appendingPathComponent("inbox/calendar", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let name = "calendar-\(formatter.string(from: now)).json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Snapshot(generated_at: ISO8601DateFormatter().string(from: now), events: items))
        let target = directory.appendingPathComponent(name)
        let temp = directory.appendingPathComponent(".\(name).tmp")
        try data.write(to: temp)
        _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
        defaults.set(hash, forKey: lastHashKey)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("calendar-") && $0.hasSuffix(".json") }.sorted()
        for old in files.dropLast(3) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(old)) }
        return target
    }
}

/// Keeps the calendar links current while sharing is on: shortly after launch, then every 30 minutes.
@MainActor
final class CalendarLinksScheduler {
    static let shared = CalendarLinksScheduler()
    private var loop: Task<Void, Never>?

    func start() {
        guard self.loop == nil else { return }
        self.loop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            while !Task.isCancelled {
                self?.exportNow()
                try? await Task.sleep(nanoseconds: 1800 * 1_000_000_000)
            }
        }
    }

    func exportNow() {
        let settings = SettingsStore.shared
        guard settings.shareCalendarWithMyOSEnabled,
              let data = ContactsInboxExporter.dataDirectory(brainOverride: settings.meetingBrainFolderOverride) else { return }
        Task.detached(priority: .utility) {
            let now = Date()
            guard let candidates = CalendarLinks.fetch(start: now - CalendarLinks.rangeBefore, end: now + CalendarLinks.rangeAfter) else {
                DebugLogger.shared.warning("Calendar links skipped: no Calendar access", source: "CalendarLinks")
                return
            }
            let people = PeopleDatabase.emailMap(emails: candidates.flatMap(\.emails))
            let items = CalendarLinks.items(candidates: candidates, people: people)
            do {
                if let file = try CalendarLinks.write(items: items, dataDirectory: data) {
                    DebugLogger.shared.info("Linked \(items.count) calendar events to known people (\(file.lastPathComponent))", source: "CalendarLinks")
                } else {
                    DebugLogger.shared.info("Calendar links unchanged", source: "CalendarLinks")
                }
            } catch {
                DebugLogger.shared.warning("Calendar links export failed: \(error.localizedDescription)", source: "CalendarLinks")
            }
        }
    }
}
