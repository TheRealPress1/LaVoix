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
        /// False for calendars that cannot take new events (holidays, subscribed feeds, shared read-only calendars).
        var writable = true
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
        /// Invitees' email addresses (not you). Kept in memory only, to recognise people; never written anywhere.
        var attendeeEmails: [String] = []
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
    /// Which address each calendar belongs to, read once from Calendar's own database (empty when that is not possible).
    @Published private(set) var ownerEmails: [String: String] = [:]
    /// Your photo and initials from the "Me" card in Contacts, for the avatar in the new-event form.
    @Published private(set) var me: CalendarMe?
    private var identityLoaded = false
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
        store.calendars = [
            CalendarInfo(id: "sample-work", title: "Work", account: "Google", color: .purple),
            CalendarInfo(id: "sample-home", title: "Home", account: "iCloud", color: .green),
            CalendarInfo(id: "sample-team", title: "Team", account: "Google", color: .orange),
        ]
        store.ownerEmails = ["sample-work": "you@example.com", "sample-team": "you@work.example.com"]
        store.me = CalendarMe(photo: nil, initials: "GS")
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
        // nil means "every calendar"; an empty list means everything has been hidden.
        let included = self.includedCalendars()
        if Self.nothingToShow(included) {
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

    /// The day the arrows land on, and the month the grid should show for it. A step that crosses into another month takes the grid with it, so
    /// the chosen day is never drawn as one of the faded days of a neighbouring month.
    static func step(selected: Date, displayedMonth: Date, byDays offset: Int, calendar: Calendar = .current) -> (day: Date, month: Date)? {
        guard let moved = calendar.date(byAdding: .day, value: offset, to: selected) else { return nil }
        let day = calendar.startOfDay(for: moved)
        let sameMonth = calendar.isDate(day, equalTo: displayedMonth, toGranularity: .month)
        return (day, sameMonth ? displayedMonth : self.startOfMonth(day, calendar: calendar))
    }

    /// The arrows next to the month name: one day at a time (the list on the right follows), not a month at a time.
    func showDay(offset: Int) {
        guard let next = Self.step(selected: self.selectedDay, displayedMonth: self.displayedMonth, byDays: offset) else { return }
        self.selectedDay = next.day
        if next.month != self.displayedMonth {
            self.displayedMonth = next.month
            self.reloadMonth()
        }
    }

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
        let included = self.includedCalendars()
        if Self.nothingToShow(included) { self.monthEvents = []; return }
        let predicate = self.store.predicateForEvents(withStart: first, end: end, calendars: included)
        let fetched = self.store.events(matching: predicate)
        self.monthEvents = Self.merged(fetched
            .filter { $0.status != .canceled && !Self.isDeclined($0) }
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .prefix(600)
            .map(Self.makeEvent))
        let perAccount = Dictionary(grouping: fetched, by: { $0.calendar?.source.title ?? "?" }).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ", ")
        let summary = "\(fetched.count) events in the grid (\(perAccount)); showing \(self.monthEvents.count) after merging duplicates"
        if summary != self.lastMonthSummary {
            self.lastMonthSummary = summary
            DebugLogger.shared.info("Calendar month: \(summary)", source: "Calendar")
        }
    }

    // MARK: - Which calendars

    /// nil means "all of them" (nothing hidden); otherwise the calendars still shown.
    private func includedCalendars() -> [EKCalendar]? {
        Self.visible(self.store.calendars(for: .event), hidden: self.hiddenCalendarIDs) { $0.calendarIdentifier }
    }

    /// nil = nothing is hidden, so ask for every calendar; otherwise only the ones not hidden.
    static func visible<T>(_ items: [T], hidden: Set<String>, id: (T) -> String) -> [T]? {
        hidden.isEmpty ? nil : items.filter { !hidden.contains(id($0)) }
    }

    /// True only when every calendar has been hidden. "All calendars" (nil) is not "nothing".
    static func nothingToShow<T>(_ included: [T]?) -> Bool {
        included?.isEmpty == true
    }

    /// Reads the list of calendars across every account on this Mac (iCloud, Google, Exchange, ...).
    func loadCalendars() {
        guard self.access == .granted else { self.calendars = []; return }
        self.calendars = self.store.calendars(for: .event)
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title, color: Color(nsColor: $0.color), writable: $0.allowsContentModifications) }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
        // Which accounts and how many calendars each (never event titles), so a missing account can be spotted in the log.
        let summary = Dictionary(grouping: self.calendars, by: \.account).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ", ")
        if summary != self.lastCalendarSummary {
            self.lastCalendarSummary = summary
            DebugLogger.shared.info("Calendars seen: \(summary.isEmpty ? "none" : summary); hidden: \(self.hiddenCalendarIDs.count)", source: "Calendar")
        }
    }

    private var lastCalendarSummary = ""
    private var lastMonthSummary = ""

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

    /// The meeting to give a heads-up for: one that starts within the next 2 minutes or began in the last 5 minutes, and
    /// hasn't been shown yet.
    static func dueForPrompt(events: [Event], now: Date, prompted: Set<String>) -> Event? {
        events.first { event in
            event.looksLikeMeeting && !prompted.contains(event.id)
                && event.start.timeIntervalSince(now) <= 120 && now.timeIntervalSince(event.start) <= 300
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
            attendeeEmails: (event.attendees ?? []).filter { !CalendarLinks.isMe($0) }.compactMap { participant in
                let raw = participant.url.absoluteString
                return raw.lowercased().hasPrefix("mailto:") ? String(raw.dropFirst(7)).lowercased() : nil
            },
            calendarTitle: event.calendar?.title ?? ""
        )
    }
}

// MARK: - New events

/// You, as the new-event form shows you: the photo on your "Me" card (if there is one) and your initials.
struct CalendarMe {
    let photo: NSImage?
    let initials: String
}

/// Why an event could not be saved, in words.
enum CalendarWriteError: LocalizedError {
    case noAccess, noCalendar

    var errorDescription: String? {
        switch self {
        case .noAccess: "Calendar access is not allowed, so the event could not be saved."
        case .noCalendar: "No calendar on this Mac takes new events. Add one in the Calendar app."
        }
    }
}

extension CalendarStore {
    /// The lengths offered for a new event, in minutes.
    static let newEventLengths = [15, 30, 45, 60, 120]
    static let newEventDefaultMinutes = 30
    private static let newEventCalendarKey = "LaVoixNotchCalendarNewEventCalendar"
    /// The first and last start a day offers (the form steps in quarter hours).
    private static let latestQuarter = 23 * 60 + 45

    /// Where a new event on `day` starts unless told otherwise: today, the next quarter hour at least five minutes away; any other day, 9:00.
    static func defaultStart(on day: Date, now: Date, calendar: Calendar = .current) -> Date {
        let dayStart = calendar.startOfDay(for: day)
        guard calendar.isDate(day, inSameDayAs: now) else {
            return calendar.date(byAdding: .hour, value: 9, to: dayStart) ?? dayStart
        }
        let minutesIntoDay = Int(now.addingTimeInterval(5 * 60).timeIntervalSince(dayStart) / 60)
        let quarter = min(latestQuarter, (minutesIntoDay + 14) / 15 * 15)
        return calendar.date(byAdding: .minute, value: quarter, to: dayStart) ?? now
    }

    /// `start` moved by `minutes`, kept inside its own day (00:00 to 23:45).
    static func shifted(_ start: Date, byMinutes minutes: Int, calendar: Calendar = .current) -> Date {
        let dayStart = calendar.startOfDay(for: start)
        let current = Int(start.timeIntervalSince(dayStart) / 60)
        let moved = max(0, min(latestQuarter, current + minutes))
        return calendar.date(byAdding: .minute, value: moved, to: dayStart) ?? start
    }

    /// `start` on the day `days` away, at the same time of day.
    static func shifted(_ start: Date, byDays days: Int, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: days, to: start) ?? start
    }

    /// What goes into the calendar for a typed title: trimmed and kept to one line; empty becomes "New event" (as the Calendar app does).
    static func cleanTitle(_ typed: String) -> String {
        let line = typed.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? "New event" : String(line.prefix(200))
    }

    /// Calendars a new event can be saved to, in the order the Calendar app lists them.
    var writableCalendars: [CalendarInfo] { self.calendars.filter(\.writable) }

    /// The calendar a new event goes to unless chosen: the one chosen last time, else the Calendar app's own default, else the first that takes events.
    func preferredNewEventCalendarID() -> String? {
        let writable = self.writableCalendars
        if let saved = UserDefaults.standard.string(forKey: Self.newEventCalendarKey), writable.contains(where: { $0.id == saved }) { return saved }
        if !self.isSample, let id = self.store.defaultCalendarForNewEvents?.calendarIdentifier, writable.contains(where: { $0.id == id }) { return id }
        return writable.first?.id
    }

    /// The places a new event can go, as the account picker lists them (with the address each belongs to when it is known).
    func saveTargets() -> [CalendarSaveTarget] {
        self.writableCalendars.map { info in
            let email = self.ownerEmails[info.id] ?? (info.account.contains("@") ? info.account.lowercased() : nil)
            return CalendarSaveTarget(id: info.id, calendarTitle: info.title, accountTitle: info.account, email: email)
        }
    }

    func color(ofCalendar id: String?) -> Color {
        self.calendars.first { $0.id == id }?.color ?? .gray
    }

    /// Reads your photo and the owner address of each calendar, once, off the main thread (it is only needed when the form is opened).
    func loadIdentityIfNeeded() {
        guard !self.identityLoaded, !self.isSample else { return }
        self.identityLoaded = true
        Task {
            let loaded = await Task.detached(priority: .utility) { (CalendarOwner.ownerEmails(), CalendarOwner.me()) }.value
            self.ownerEmails = loaded.0.emails
            self.me = loaded.1.map { CalendarMe(photo: $0.thumbnail.flatMap { NSImage(data: $0) }, initials: $0.initials) }
            DebugLogger.shared.info("Calendar owners: \(loaded.0.summary); Me card: \(loaded.1 == nil ? "not available" : (loaded.1?.thumbnail == nil ? "no photo" : "photo"))", source: "Calendar")
        }
    }

    func rememberNewEventCalendar(_ id: String) {
        UserDefaults.standard.set(id, forKey: Self.newEventCalendarKey)
    }

    /// Saves a new event in the Mac's Calendar (which syncs it to the account the calendar belongs to: iCloud, Google, ...), shows it in the
    /// notch at once, and returns it.
    @discardableResult
    func createEvent(title: String, start: Date, minutes: Int, calendarID: String?) throws -> Event {
        let clean = Self.cleanTitle(title)
        let end = start.addingTimeInterval(Double(max(5, minutes)) * 60)
        if self.isSample {
            let info = self.writableCalendars.first { $0.id == calendarID } ?? self.writableCalendars.first
            let event = Event(
                id: "new|\(start.timeIntervalSince1970)", title: clean, start: start, end: end, isAllDay: false,
                color: info?.color ?? .blue, location: nil, joinURL: nil, attendeeCount: 0, calendarTitle: info?.title ?? ""
            )
            self.monthEvents.append(event)
            if end > self.now { self.events.append(event) }
            return event
        }
        guard self.access == .granted else { throw CalendarWriteError.noAccess }
        let chosen = calendarID.flatMap { id in self.store.calendars(for: .event).first { $0.calendarIdentifier == id && $0.allowsContentModifications } }
        guard let calendar = chosen ?? self.store.defaultCalendarForNewEvents else { throw CalendarWriteError.noCalendar }
        let event = EKEvent(eventStore: self.store)
        event.title = clean
        event.startDate = start
        event.endDate = end
        event.calendar = calendar
        try self.store.save(event, span: .thisEvent, commit: true)
        DebugLogger.shared.info("Calendar: a new event was saved in \"\(calendar.title)\" (\(calendar.source.title))", source: "Calendar")
        self.reload()
        return Self.makeEvent(event)
    }

    /// Selects `day` and makes sure the month grid shows it (and has its events loaded).
    func reveal(day: Date) {
        let target = Calendar.current.startOfDay(for: day)
        self.selectedDay = target
        if !Calendar.current.isDate(target, equalTo: self.displayedMonth, toGranularity: .month) {
            self.displayedMonth = Self.startOfMonth(target)
            self.reloadMonth()
        }
    }

    /// Removes an event this app just saved (only the self-test uses it, to leave the calendar as it found it).
    func deleteEvent(identifier: String) throws {
        guard let event = self.store.event(withIdentifier: identifier) else { return }
        try self.store.remove(event, span: .thisEvent, commit: true)
        self.reload()
    }
}
