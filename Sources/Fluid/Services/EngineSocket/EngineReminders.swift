import EventKit
import Foundation

/// Your Apple Reminders, for myOS's to-do card: what is due today or overdue and what you finished today, and ticking one off (or back on)
/// from the card. That is the only change it ever makes; nothing is created or deleted, and nothing here is logged. macOS asks once (Reminders permission), credited to myOS.
nonisolated protocol EngineRemindersProviding: Sendable {
    /// {authorization: "authorized"|"write_only"|"denied"|"restricted"|"not_determined"}
    func status() async -> [String: Any]
    /// Shows macOS's Reminders prompt if it hasn't been answered; returns the same shape as `status`.
    func request() async -> [String: Any]
    /// {items: [{id, title, list, due?, due_has_time, priority, completed}]}: incomplete reminders due by the end of today (overdue included),
    /// then ones completed since the start of today. Undated reminders are left out, as in Reminders' own Today list.
    func today() async throws -> [String: Any]
    /// Marks one reminder (by its `id` from `today`) done or not done, the same as ticking it in Reminders.
    func setCompleted(id: String, completed: Bool) async throws
}

nonisolated enum EngineRemindersError: LocalizedError, Equatable {
    case notAllowed
    case notFound
    var errorDescription: String? {
        switch self {
        case .notAllowed: "Allow Reminders for the myOS engine first (macOS asks once)."
        case .notFound: "That reminder isn't in Reminders any more."
        }
    }
}

nonisolated enum RemindersRules {
    static func name(_ s: EKAuthorizationStatus) -> String {
        switch s {
        case .fullAccess: "authorized"
        case .writeOnly: "write_only"
        case .denied: "denied"
        case .restricted: "restricted"
        default: "not_determined"
        }
    }

    /// A due date as myOS shows it: a bare `YYYY-MM-DD` when the reminder has no time, an ISO-8601 instant when it does.
    static func due(_ c: DateComponents?, calendar: Calendar = .current) -> (text: String, hasTime: Bool)? {
        guard let c, let y = c.year, let m = c.month, let d = c.day else { return nil }
        if c.hour == nil { return (String(format: "%04d-%02d-%02d", y, m, d), false) }
        var cal = calendar
        if let tz = c.timeZone { cal.timeZone = tz }
        guard let date = cal.date(from: c) else { return (String(format: "%04d-%02d-%02d", y, m, d), false) }
        return (ISO8601DateFormatter().string(from: date), true)
    }

    /// Reminders first by due time (dated before undated is not a case here), then by title, so the card is stable between reads.
    static func sort(_ items: [[String: Any]]) -> [[String: Any]] {
        items.sorted {
            let a = ($0["due"] as? String) ?? "", b = ($1["due"] as? String) ?? ""
            if a != b { return a < b }
            return (($0["title"] as? String) ?? "") < (($1["title"] as? String) ?? "")
        }
    }
}

nonisolated struct LiveEngineReminders: EngineRemindersProviding {
    func status() async -> [String: Any] { ["authorization": RemindersRules.name(EKEventStore.authorizationStatus(for: .reminder))] }

    func request() async -> [String: Any] {
        let store = EKEventStore()
        _ = try? await store.requestFullAccessToReminders()
        return ["authorization": RemindersRules.name(EKEventStore.authorizationStatus(for: .reminder))]
    }

    func today() async throws -> [String: Any] {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { throw EngineRemindersError.notAllowed }
        let store = EKEventStore()
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let endOfToday = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? Date()

        func fetch(_ predicate: NSPredicate) async -> [[String: Any]] {
            await withCheckedContinuation { (continuation: CheckedContinuation<[[String: Any]], Never>) in
                store.fetchReminders(matching: predicate) { reminders in
                    let rows: [[String: Any]] = (reminders ?? []).map { r in
                        var row: [String: Any] = [
                            "id": r.calendarItemIdentifier,
                            "title": r.title ?? "",
                            "list": r.calendar?.title ?? "",
                            "priority": r.priority,
                            "completed": r.isCompleted,
                            "due_has_time": false,
                        ]
                        if let due = RemindersRules.due(r.dueDateComponents) { row["due"] = due.text; row["due_has_time"] = due.hasTime }
                        return row
                    }
                    continuation.resume(returning: rows)
                }
            }
        }

        let open = await fetch(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: endOfToday, calendars: nil))
        let done = await fetch(store.predicateForCompletedReminders(withCompletionDateStarting: startOfToday, ending: Date(), calendars: nil))
        return ["items": RemindersRules.sort(open) + RemindersRules.sort(done)]
    }

    func setCompleted(id: String, completed: Bool) async throws {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { throw EngineRemindersError.notAllowed }
        let store = EKEventStore()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { throw EngineRemindersError.notFound }
        reminder.isCompleted = completed
        try store.save(reminder, commit: true)
    }
}
