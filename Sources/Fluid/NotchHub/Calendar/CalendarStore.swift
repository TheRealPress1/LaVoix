import AppKit
import Combine
import EventKit
import Foundation
import SwiftUI

enum NotchCalendarSettings {
    private static let enabledKey = "LaVoixNotchCalendarEnabled"
    private static let promptKey = "LaVoixNotchCalendarPromptToRecord"

    /// Off until the user turns it on, because it needs Calendar access.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: self.enabledKey) }
    }

    /// Offer to record when a meeting with a call link or other attendees starts.
    static var promptsToRecord: Bool {
        get { UserDefaults.standard.object(forKey: self.promptKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: self.promptKey) }
    }
}

/// Today and tomorrow from your calendars (read-only, via EventKit), and a nudge when a meeting starts.
@MainActor
final class CalendarStore: ObservableObject {
    static let shared = CalendarStore()

    enum Access: Equatable { case unknown, granted, denied }

    struct Event: Identifiable, Equatable {
        let id: String
        var title: String
        var start: Date
        var end: Date
        var isAllDay: Bool
        var color: Color
        var location: String?
        var joinURL: URL?
        var attendeeCount: Int

        /// Worth offering to record: a call link, or other people invited.
        var looksLikeMeeting: Bool { !self.isAllDay && (self.joinURL != nil || self.attendeeCount >= 2) }
    }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var events: [Event] = []
    /// Ticks forward so "in 5 min" labels stay current.
    @Published private(set) var now = Date()

    /// Called once per meeting when it is time to offer recording.
    var onMeetingDue: ((Event) -> Void)?

    private let store = EKEventStore()
    private var timer: Timer?
    private var changeObserver: NSObjectProtocol?
    private var prompted: Set<String> = []

    init() {}

    /// Sample data for debug rendering; never touches EventKit.
    static func sample(access: Access = .granted, empty: Bool = false) -> CalendarStore {
        let store = CalendarStore()
        store.access = access
        let now = Date()
        store.now = now
        guard access == .granted, !empty else { return store }
        func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }
        store.events = [
            Event(id: "1", title: "Design sync", start: at(12), end: at(42), isAllDay: false, color: .blue, location: "Zoom", joinURL: URL(string: "https://zoom.us/j/123456789"), attendeeCount: 4),
            Event(id: "2", title: "Lunch with Maya", start: at(150), end: at(210), isAllDay: false, color: .green, location: "Café Berlin", joinURL: nil, attendeeCount: 2),
            Event(id: "3", title: "Investor update", start: at(330), end: at(360), isAllDay: false, color: .orange, location: nil, joinURL: URL(string: "https://meet.google.com/abc-defg-hij"), attendeeCount: 5),
            Event(id: "4", title: "Gym", start: at(1440 + 60), end: at(1440 + 120), isAllDay: false, color: .purple, location: nil, joinURL: nil, attendeeCount: 0),
        ]
        return store
    }

    // MARK: - Lifecycle

    func start() {
        self.refreshAccess()
        guard self.timer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        self.changeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: self.store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        self.reload()
    }

    func stop() {
        self.timer?.invalidate()
        self.timer = nil
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        self.changeObserver = nil
    }

    /// Asks macOS for Calendar access (shows the system prompt the first time).
    func requestAccess() {
        Task {
            _ = try? await self.store.requestFullAccessToEvents()
            self.refreshAccess()
            self.reload()
        }
    }

    private func refreshAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: self.access = .granted
        case .notDetermined: self.access = .unknown
        default: self.access = .denied
        }
    }

    private func tick() {
        self.now = Date()
        self.reload()
        guard NotchCalendarSettings.promptsToRecord,
              let due = Self.dueForPrompt(events: self.events, now: self.now, prompted: self.prompted) else { return }
        self.prompted.insert(due.id)
        self.onMeetingDue?(due)
    }

    func reload() {
        self.refreshAccess()
        guard self.access == .granted else { self.events = []; return }
        self.now = Date()
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: self.now)
        guard let end = calendar.date(byAdding: .day, value: 2, to: dayStart) else { return }
        let predicate = self.store.predicateForEvents(withStart: dayStart, end: end, calendars: nil)
        let now = self.now
        self.events = self.store.events(matching: predicate)
            .filter { $0.endDate > now && $0.status != .canceled && !Self.isDeclined($0) }
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .prefix(12)
            .map(Self.makeEvent)
    }

    // MARK: - Logic (pure, so it can be tested)

    /// The meeting to offer recording for: one that starts within the next 30 seconds or began in the last 5
    /// minutes, and hasn't been offered yet.
    static func dueForPrompt(events: [Event], now: Date, prompted: Set<String>) -> Event? {
        events.first { event in
            event.looksLikeMeeting && !prompted.contains(event.id)
                && event.start.timeIntervalSince(now) <= 30 && now.timeIntervalSince(event.start) <= 300
        }
    }

    /// The event to feature: the one in progress, otherwise the next to start. All-day events never count.
    static func featured(from events: [Event], now: Date) -> Event? {
        events.first { !$0.isAllDay && $0.end > now }
    }

    private static let joinHosts = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com",
        "around.co", "gotomeeting.com", "gotomeet.me", "bluejeans.com", "chime.aws", "meet.jit.si", "slack.com/huddle",
    ]

    /// First video-call link in the event's URL, location or notes.
    static func joinURL(in texts: [String?]) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, options: [], range: range) {
                guard let url = match.url, url.scheme?.hasPrefix("http") == true else { continue }
                let target = (url.host ?? "") + url.path
                if self.joinHosts.contains(where: { target.contains($0) }) { return url }
            }
        }
        return nil
    }

    /// "Now", "in 12 min", "in 2h 10m", or a clock time for later events.
    static func whenLabel(start: Date, end: Date, now: Date) -> String {
        if start <= now { return "Now" }
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes < 60 { return "in \(minutes) min" }
        if minutes < 360 { return "in \(minutes / 60)h \(minutes % 60)m" }
        return start.formatted(date: .omitted, time: .shortened)
    }

    private static func isDeclined(_ event: EKEvent) -> Bool {
        event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
    }

    private static func makeEvent(_ event: EKEvent) -> Event {
        Event(
            id: "\(event.eventIdentifier ?? event.title ?? "event")|\(event.startDate.timeIntervalSince1970)",
            title: (event.title?.isEmpty == false ? event.title : nil) ?? "Untitled",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            color: Color(nsColor: event.calendar?.color ?? .systemBlue),
            location: event.location.flatMap { $0.isEmpty ? nil : $0 },
            joinURL: Self.joinURL(in: [event.url?.absoluteString, event.location, event.notes]),
            attendeeCount: event.attendees?.count ?? 0
        )
    }
}
