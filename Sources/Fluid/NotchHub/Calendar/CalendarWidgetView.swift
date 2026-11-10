import AppKit
import SwiftUI

/// A month grid on the left (today in red, dots on days with events) and the chosen day's events on the right.
struct CalendarWidgetView: View {
    @ObservedObject var store: CalendarStore
    /// The recordings that exist, so a meeting that was recorded shows its notes instead of a Record button.
    @ObservedObject var recorded: RecordedMeetingsStore
    var staticLayout = false
    /// True while the new-event form is showing in place of the day's list.
    @State private var creating: Bool
    /// The meeting opened from the day list (its details replace the list).
    @State private var detail: CalendarStore.Event?
    /// What a render preview shows of the new-event form (nil for the real thing).
    private let preview: CalendarNewEventPreview?
    private let eventPreview: CalendarEventPreview?

    init(store: CalendarStore, recorded: RecordedMeetingsStore = .shared, staticLayout: Bool = false, startCreating: Bool = false, preview: CalendarNewEventPreview? = nil, eventPreview: CalendarEventPreview? = nil) {
        self._store = ObservedObject(wrappedValue: store)
        self._recorded = ObservedObject(wrappedValue: recorded)
        self.staticLayout = staticLayout
        self.preview = preview
        self.eventPreview = eventPreview
        self._creating = State(initialValue: startCreating)
        self._detail = State(initialValue: eventPreview.flatMap { $0.eventIndex < store.events.count ? store.events[$0.eventIndex] : nil })
    }

    private static let accent = Color(red: 0.96, green: 0.32, blue: 0.29)

    var body: some View {
        Group {
            switch self.store.access {
            case .granted: self.monthAndDay
            case .unknown: self.permissionCard(denied: false)
            case .denied: self.permissionCard(denied: true)
            }
        }
        .foregroundStyle(.white)
        .onAppear {
            if !self.staticLayout { self.store.reload() }
            self.takePendingDetail()
        }
        .onChange(of: self.store.pendingDetail) { _, _ in self.takePendingDetail() }
        // Which meetings were recorded, looked at again while the tab is on screen (and for the day chosen).
        .task(id: self.store.selectedDay) { await self.watchRecordings() }
        // Another day chosen: its list, not the details of a meeting on the day before.
        .onChange(of: self.store.selectedDay) { _, day in
            if let open = self.detail, !Calendar.current.isDate(open.start, inSameDayAs: day) { self.detail = nil }
        }
    }

    private func watchRecordings() async {
        guard !self.staticLayout else { return }
        while !Task.isCancelled {
            await self.recorded.refresh(since: self.store.selectedDay)
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
    }

    /// A tapped "meeting set" card asks for its meeting's details.
    private func takePendingDetail() {
        guard let event = self.store.pendingDetail else { return }
        self.store.pendingDetail = nil
        self.creating = false
        self.detail = event
    }

    // MARK: - Month and day

    private var monthAndDay: some View {
        HStack(alignment: .top, spacing: 0) {
            self.monthGrid
                .frame(width: 292)
            Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1).padding(.horizontal, 18)
            self.dayList
                .frame(maxWidth: .infinity)
        }
    }

    private var monthGrid: some View {
        let calendar = Calendar.current
        let days = CalendarStore.gridDays(forMonth: self.store.displayedMonth)
        let weekdaySymbols = (0..<7).map { calendar.veryShortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1 + $0) % 7] }
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
        return VStack(spacing: 4) {
            HStack {
                self.chevron("chevron.left", help: "Previous day") { self.store.showDay(offset: -1) }
                Spacer()
                Button { self.store.jumpToToday() } label: {
                    Text(self.store.displayedMonth.formatted(.dateTime.month(.wide).year()))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help("Go to today")
                Spacer()
                self.chevron("chevron.right", help: "Next day") { self.store.showDay(offset: 1) }
            }
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.4)).frame(height: 14)
                }
                ForEach(days, id: \.self) { day in
                    DayCell(
                        day: day,
                        inMonth: calendar.isDate(day, equalTo: self.store.displayedMonth, toGranularity: .month),
                        isToday: calendar.isDateInToday(day),
                        isSelected: calendar.isDate(day, inSameDayAs: self.store.selectedDay),
                        dotColor: CalendarStore.events(on: day, in: self.store.monthEvents).first?.color
                    )
                    .onTapGesture { self.store.selectedDay = calendar.startOfDay(for: day) }
                }
            }
        }
    }

    private func chevron(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                .frame(width: 26, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var dayList: some View {
        let events = CalendarStore.events(on: self.store.selectedDay, in: self.store.monthEvents)
        return VStack(alignment: .leading, spacing: 8) {
            if !self.creating, self.detail == nil {
                HStack {
                    Text(self.dayTitle(self.store.selectedDay))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                    Spacer(minLength: 0)
                    if self.store.writableCalendars.isEmpty == false || self.store.isSample {
                        Button { self.creating = true } label: {
                            Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Color.white.opacity(0.12)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("New event")
                        .accessibilityLabel("New event")
                    }
                }
            }
            if let detail = self.detail {
                CalendarEventDetailView(
                    store: self.store, event: detail, recorded: self.recorded, staticLayout: self.staticLayout,
                    screen: self.eventPreview?.screen ?? .detail, confirmingDelete: self.eventPreview?.confirmingDelete ?? false,
                    newGuests: self.eventPreview?.newGuests ?? [], previewQuery: self.eventPreview?.query ?? "",
                    previewSuggestions: self.eventPreview?.suggestions ?? []
                ) {
                    self.detail = nil
                }
                .id(detail.id)
            } else if self.creating {
                CalendarNewEventForm(
                    store: self.store, day: self.store.selectedDay, staticLayout: self.staticLayout,
                    initialTitle: self.staticLayout ? "Call with Martin" : "",
                    screen: self.preview?.screen ?? .form, guests: self.preview?.guests ?? [],
                    guestQuery: self.preview?.query ?? "", previewSuggestions: self.preview?.suggestions ?? []
                ) {
                    self.creating = false
                }
            } else if events.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "calendar").font(.system(size: 22, weight: .light)).foregroundStyle(.white.opacity(0.3))
                    Text("Nothing scheduled").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.45))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.staticLayout {
                self.rows(Array(events.prefix(3)))
            } else {
                ScrollView(.vertical, showsIndicators: false) { self.rows(events) }
            }
        }
    }

    private func rows(_ events: [CalendarStore.Event]) -> some View {
        VStack(spacing: 6) {
            ForEach(events) { event in
                let recording = self.recorded.recording(for: event)
                EventRow(
                    event: event, now: self.store.now, day: self.store.selectedDay, recording: recording,
                    onOpenRecording: { if let recording, !self.staticLayout { MyOSLink.openMeeting(recording.id) } }
                ) { self.detail = event }
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    // MARK: - Permission

    private func permissionCard(denied: Bool) -> some View {
        HStack(spacing: 18) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 30, weight: .light)).foregroundStyle(.white.opacity(0.7))
            VStack(alignment: .leading, spacing: 6) {
                Text("Allow LaVoix to see your calendar").font(.system(size: 15, weight: .semibold))
                Text("Your month and next meeting show up here, and LaVoix can offer to record a meeting when it starts. Events are read on this Mac and never leave it.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if denied {
                        self.pill("Open Privacy Settings", prominent: true) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        self.pill("Check again", prominent: false) { self.store.reload() }
                    } else {
                        self.pill("Allow access", prominent: true) { self.store.requestAccess() }
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pill(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? Color.black : Color.white)
                .padding(.horizontal, 14).frame(height: 26)
                .background(Capsule().fill(prominent ? Color.white : Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }

    fileprivate static var todayRed: Color { Self.accent }
}

private struct DayCell: View {
    let day: Date
    let inMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let dotColor: Color?

    var body: some View {
        ZStack {
            if self.isToday {
                Circle().fill(CalendarWidgetView.todayRed).frame(width: 22, height: 22)
            } else if self.isSelected {
                Circle().fill(Color.white.opacity(0.16)).frame(width: 22, height: 22)
            }
            Text("\(Calendar.current.component(.day, from: self.day))")
                .font(.system(size: 12.5, weight: self.isToday ? .bold : .regular))
                .foregroundStyle(self.inMonth ? Color.white : Color.white.opacity(0.28))
        }
        .overlay(alignment: .bottom) {
            if let dotColor {
                Circle().fill(self.isToday ? Color.white : dotColor).frame(width: 3.5, height: 3.5).offset(y: 2)
                    .opacity(self.inMonth ? 1 : 0.4)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 26)
        .contentShape(Rectangle())
    }
}

private struct EventRow: View {
    let event: CalendarStore.Event
    let now: Date
    let day: Date
    /// The recording of this meeting, when there is one: its notes icon takes the place of the Record button.
    var recording: RecordedMeetings.Entry?
    var onOpenRecording: () -> Void = {}
    /// Pressing the row (anywhere but its buttons) opens the meeting's details.
    var onOpen: () -> Void = {}
    @State private var hovering = false

    /// The meeting is over: the row is faded, but its Join button still works (a call can be rejoined).
    private var past: Bool { self.event.end <= self.now }

    var body: some View {
        let live = self.event.start <= self.now && self.event.end > self.now
        let showsActions = self.hovering && (self.event.joinURL != nil || self.event.looksLikeMeeting)
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(self.event.color).frame(width: 3, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(self.event.title).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                    Text(self.timeText).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
            }
            // A meeting that has passed is dimmed so the day reads at a glance; resting the pointer on it brings it back.
            .opacity(self.past ? (self.hovering ? 0.8 : 0.4) : 1)
            Spacer(minLength: 6)
            if showsActions || self.recording != nil {
                HStack(spacing: 6) {
                    if showsActions, let url = self.event.joinURL { self.pill("Join", prominent: false) { NSWorkspace.shared.open(url) } }
                    if self.recording != nil {
                        Button { self.onOpenRecording() } label: { MeetingNotesIcon(size: 24) }
                            .buttonStyle(.plain)
                            .help("Open the notes and transcript in myOS")
                            .accessibilityLabel("Open this meeting's notes in myOS")
                    } else if showsActions {
                        Button { NotchMeetingCardController.shared.record(self.event) } label: {
                            // A plain red record dot, like a camera's record light.
                            ZStack {
                                Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 1.5).frame(width: 22, height: 22)
                                Circle().fill(Color(red: 1, green: 0.27, blue: 0.23)).frame(width: 12, height: 12)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Record this meeting")
                    }
                }
            } else if live {
                Text("Now").font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(self.hovering ? 0.1 : (self.past ? 0.035 : 0.06))))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(self.past && !self.hovering ? 0.05 : 0.1), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { self.onOpen() }
        .onHover { self.hovering = $0 }
        .accessibilityAddTraits(.isButton)
        .help("Open this meeting")
    }

    private var timeText: String {
        if self.event.isAllDay { return "All day" + (self.event.location.map { " · \($0)" } ?? "") }
        let time = "\(self.event.start.formatted(date: .omitted, time: .shortened)) – \(self.event.end.formatted(date: .omitted, time: .shortened))"
        return time + (self.event.location.map { " · \($0)" } ?? "")
    }

    private func pill(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(prominent ? Color.black : Color.white)
                .padding(.horizontal, 10).frame(height: 22)
                .background(Capsule().fill(prominent ? Color.white : Color.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
    }
}

/// What a render preview shows of the new-event form: which screen, the guests already chosen, what is typed and what the search offers.
struct CalendarNewEventPreview {
    var screen: CalendarNewEventForm.Screen = .form
    var guests: [CalendarGuest] = []
    var query = ""
    var suggestions: [CalendarGuest] = []
}

/// What a render preview shows of a meeting's details: which meeting of the sample day, which screen, and (for the invite search) what is typed.
struct CalendarEventPreview {
    var eventIndex = 0
    var screen: CalendarEventDetailView.Screen = .detail
    var confirmingDelete = false
    var newGuests: [CalendarGuest] = []
    var query = ""
    var suggestions: [CalendarGuest] = []
}
