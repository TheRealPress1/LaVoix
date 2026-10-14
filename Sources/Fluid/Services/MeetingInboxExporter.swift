import Foundation

/// Tells myOS who was in a meeting you recorded, so it can count it as time with them. Only opaque person ids go in the
/// file (resolved locally from myOS's own database); attendee emails never leave memory.
nonisolated enum MeetingInboxExporter {
    struct Payload: Codable, Equatable {
        var schema = 1
        var source = "meeting"
        var external_id: String
        var occurred_at: String
        var ended_at: String?
        var title: String
        var minutes: Int
        var person_ids: [String]
        var unknown_attendees: Int
        var note_file: String?
    }

    static func payload(
        meetingID: UUID, title: String, start: Date, end: Date?, personIDs: [String], unknownAttendees: Int, noteFile: String?
    ) -> Payload {
        let iso = ISO8601DateFormatter()
        let minutes = end.map { max(1, Int(($0.timeIntervalSince(start) / 60).rounded())) } ?? 1
        return Payload(
            external_id: "meeting:\(meetingID.uuidString.lowercased())", occurred_at: iso.string(from: start),
            ended_at: end.map(iso.string(from:)), title: title, minutes: minutes,
            person_ids: Array(Set(personIDs)).sorted(), unknown_attendees: max(0, unknownAttendees), note_file: noteFile
        )
    }

    static func fileName(meetingID: UUID, start: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return "meeting-\(formatter.string(from: start))-\(meetingID.uuidString.lowercased().prefix(8)).json"
    }

    /// Writes `<data>/inbox/meetings/<name>.json` atomically; the same meeting always lands in the same file.
    @discardableResult
    static func write(_ payload: Payload, meetingID: UUID, start: Date, dataDirectory: URL) throws -> URL {
        let directory = dataDirectory.appendingPathComponent("inbox/meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let name = fileName(meetingID: meetingID, start: start)
        let target = directory.appendingPathComponent(name)
        let temp = directory.appendingPathComponent(".\(name).tmp")
        try encoder.encode(payload).write(to: temp)
        _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
        return target
    }
}

/// Who was invited to the meeting being recorded, remembered until it ends. In memory only.
nonisolated final class MeetingAttendeeRegistry: @unchecked Sendable {
    static let shared = MeetingAttendeeRegistry()
    struct Entry { let personIDs: [String]; let unknown: Int }
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    func set(_ id: UUID, personIDs: [String], unknown: Int) {
        self.lock.withLock { self.entries[id] = Entry(personIDs: personIDs, unknown: unknown) }
    }

    func take(_ id: UUID) -> Entry? {
        self.lock.withLock { self.entries.removeValue(forKey: id) }
    }
}
