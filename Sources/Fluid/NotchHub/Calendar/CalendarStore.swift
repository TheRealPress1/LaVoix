import AppKit
import Combine
import EventKit
import Foundation
import SwiftUI

enum NotchCalendarSettings {
    private static let enabledKey = "LaVoixNotchCalendarEnabled"
    private static let promptKey = "LaVoixNotchCalendarPromptToRecord"

    /// On by default so the tab is easy to find. It reads nothing until you tap "Allow access" in the tab (or turn the
    /// setting on), because macOS asks for Calendar access then.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: self.enabledKey) as? Bool ?? true }
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

    /// One calendar (e.g. "Work") and the account it comes from (iCloud, Google, ...).
    struct CalendarInfo: Identifiable, Equatable {
        let id: String
        let title: String
        let account: String
        let color: Color
    }

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
        /// The calendar it lives in (e.g. "Work"), for telling accounts apart.
        var calendarTitle: String = ""

        /// Worth offering to record: a call link, or other people invited.
        var looksLikeMeeting: Bool { !self.isAllDay && (self.joinURL != nil || self.attendeeCount >= 2) }
    }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var events: [Event] = []
    /// Ticks forward so "in 5 min" labels stay current.
    @Published private(set) var now = Date()
    /// Every event in the visible month grid (including the days either side), for the day dots and the day list.
    @Published private(set) var monthEvents: [Event] = []
    /// First day of the month being shown.
    @Published private(set) var displayedMonth = CalendarStore.startOfMonth(Date())
    @Published var selectedDay = Calendar.current.startOfDay(for: Date())
    /// Every calendar on this Mac across all accounts, so you can choose which ones the notch shows.
    @Published private(set) var calendars: [CalendarInfo] = []
    @Published private(set) var hiddenCalendarIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "LaVoixNotchCalendarHidden") ?? [])

    /// Called once per meeting when it is time to offer recording.
    var onMeetingDue: ((Event) -> Void)?

    private let store = EKEventStore()
    /// Preview/test stores keep their made-up data and never touch EventKit.
    private(set) var isSample = false
    private var timer: Timer?
    private var changeObserver: NSObjectProtocol?
    private var prompted: Set<String> = []

    init() {}

    /// Sample data for debug rendering; never touches EventKit.
    static func sample(access: Access = .granted, empty: Bool = false) -> CalendarStore {
        let store = CalendarStore()
        store.isSample = true
        store.access = access
        let now = Date()
        store.now = now
        guard access == .granted, !empty else { return store }
        func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }
        func day(_ offset: Int, hour: Int, hours: Double = 1) -> (Date, Date) {
            let start = Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: now))!.addingTimeInterval(Double(hour) * 3600)
            return (start, start.addingTimeInterval(hours * 3600))
        }
        let (dentistStart, dentistEnd) = day(3, hour: 9)
        let (offsiteStart, offsiteEnd) = day(6, hour: 0, hours: 24)
        let (reviewStart, reviewEnd) = day(-2, hour: 15)
        let (boardStart, boardEnd) = day(9, hour: 11)
        store.events = [
            Event(id: "1", title: "Design sync", start: at(12), end: at(42), isAllDay: false, color: .blue, location: "Zoom", joinURL: URL(string: "https://zoom.us/j/123456789"), attendeeCount: 4),
            Event(id: "2", title: "Lunch with Maya", start: at(150), end: at(210), isAllDay: false, color: .green, location: "Café Berlin", joinURL: nil, attendeeCount: 2),
            Event(id: "3", title: "Investor update", start: at(330), end: at(360), isAllDay: false, color: .orange, location: nil, joinURL: URL(string: "https://meet.google.com/abc-defg-hij"), attendeeCount: 5),
        ]
        store.monthEvents = store.events + [
            Event(id: "4", title: "Dentist", start: dentistStart, end: dentistEnd, isAllDay: false, color: .purple, location: nil, joinURL: nil, attendeeCount: 0),
            Event(id: "5", title: "Team offsite", start: offsiteStart, end: offsiteEnd, isAllDay: true, color: .pink, location: "Lisbon", joinURL: nil, attendeeCount: 0),
            Event(id: "6", title: "Launch review", start: reviewStart, end: reviewEnd, isAllDay: false, color: .blue, location: nil, joinURL: nil, attendeeCount: 3),
            Event(id: "7", title: "Board prep", start: boardStart, end: boardEnd, isAllDay: false, color: .orange, location: nil, joinURL: nil, attendeeCount: 2),
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
        guard !self.isSample else { return }
        self.refreshAccess()
        guard self.access == .granted else { self.events = []; self.monthEvents = []; return }
        self.now = Date()
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: self.now)
        guard let end = calendar.date(byAdding: .day, value: 2, to: dayStart) else { return }
        self.loadCalendars()
        guard let included = self.includedCalendars(), !included.isEmpty || self.hiddenCalendarIDs.isEmpty else {
            self.events = []
            self.reloadMonth()
            return
        }
        let predicate = self.store.predicateForEvents(withStart: dayStart, end: end, calendars: included)
        let now = self.now
        self.events = Self.merged(self.store.events(matching: predicate)
            .filter { $0.endDate > now && $0.status != .canceled && !Self.isDeclined($0) }
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .map(Self.makeEvent))
            .prefix(12).map { $0 }
        self.reloadMonth()
    }

    // MARK: - Month view

    func showMonth(offset: Int) {
        guard let month = Calendar.current.date(byAdding: .month, value: offset, to: self.displayedMonth) else { return }
        self.displayedMonth = Self.startOfMonth(month)
        self.reloadMonth()
    }

    func jumpToToday() {
        self.now = Date()
        self.displayedMonth = Self.startOfMonth(self.now)
        self.selectedDay = Calendar.current.startOfDay(for: self.now)
        self.reloadMonth()
    }

    /// Loads everything in the visible grid so the days can show dots and any day's list is already there.
    func reloadMonth() {
        guard !self.isSample else { return }
        guard self.access == .granted else { self.monthEvents = []; return }
        let days = Self.gridDays(forMonth: self.displayedMonth)
        guard let first = days.first, let last = days.last, let end = Calendar.current.date(byAdding: .day, value: 1, to: last) else { return }
        guard let included = self.includedCalendars(), !included.isEmpty || self.hiddenCalendarIDs.isEmpty else { self.monthEvents = []; return }
        let predicate = self.store.predicateForEvents(withStart: first, end: end, calendars: included)
        self.monthEvents = Self.merged(self.store.events(matching: predicate)
            .filter { $0.status != .canceled && !Self.isDeclined($0) }
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .prefix(600)
            .map(Self.makeEvent))
    }

    // MARK: - Which calendars

    /// nil means "all of them" (nothing hidden); otherwise the calendars still shown.
    private func includedCalendars() -> [EKCalendar]? {
        guard !self.hiddenCalendarIDs.isEmpty else { return nil }
        return self.store.calendars(for: .event).filter { !self.hiddenCalendarIDs.contains($0.calendarIdentifier) }
    }

    /// Reads the list of calendars across every account on this Mac (iCloud, Google, Exchange, ...).
    func loadCalendars() {
        guard self.access == .granted else { self.calendars = []; return }
        self.calendars = self.store.calendars(for: .event)
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title, color: Color(nsColor: $0.color)) }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    func setCalendar(_ id: String, visible: Bool) {
        if visible { self.hiddenCalendarIDs.remove(id) } else { self.hiddenCalendarIDs.insert(id) }
        UserDefaults.standard.set(Array(self.hiddenCalendarIDs), forKey: "LaVoixNotchCalendarHidden")
        self.reload()
    }

    /// The same meeting often appears in two accounts (an invite in Google and a copy in iCloud). Show it once: same
    /// title, start and end. Prefer the copy that has a call link or more guests.
    static func merged(_ events: [Event]) -> [Event] {
        var index: [String: Int] = [:]
        var result: [Event] = []
        for event in events {
            let key = "\(event.title.lowercased())|\(event.start.timeIntervalSince1970)|\(event.end.timeIntervalSince1970)|\(event.isAllDay)"
            if let existing = index[key] {
                let old = result[existing]
                if (old.joinURL == nil && event.joinURL != nil) || (old.joinURL == nil) == (event.joinURL == nil) && event.attendeeCount > old.attendeeCount {
                    result[existing] = event
                }
                continue
            }
            index[key] = result.count
            result.append(event)
        }
        return result
    }

    static func startOfMonth(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? calendar.startOfDay(for: date)
    }

    /// The days to draw for a month: whole weeks (5 or 6 rows), starting on the calendar's first weekday.
    static func gridDays(forMonth month: Date, calendar: Calendar = .current) -> [Date] {
        let first = self.startOfMonth(month, calendar: calendar)
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let length = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        let total = ((lead + length + 6) / 7) * 7
        guard let start = calendar.date(byAdding: .day, value: -lead, to: first) else { return [] }
        return (0..<total).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// Events that touch a given day (multi-day and all-day events show on every day they cover).
    static func events(on day: Date, in events: [Event], calendar: Calendar = .current) -> [Event] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return events.filter { $0.start < end && $0.end > start }
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
            attendeeCount: event.attendees?.count ?? 0,
            calendarTitle: event.calendar?.title ?? ""
        )
    }
}
