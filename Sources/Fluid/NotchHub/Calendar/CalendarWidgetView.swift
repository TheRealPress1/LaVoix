import AppKit
import SwiftUI

/// A month grid on the left (today in red, dots on days with events) and the chosen day's events on the right.
struct CalendarWidgetView: View {
    @ObservedObject var store: CalendarStore
    var staticLayout = false

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
        .onAppear { if !self.staticLayout { self.store.reload() } }
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
                self.chevron("chevron.left") { self.store.showMonth(offset: -1) }
                Spacer()
                Button { self.store.jumpToToday() } label: {
                    Text(self.store.displayedMonth.formatted(.dateTime.month(.wide).year()))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help("Go to today")
                Spacer()
                self.chevron("chevron.right") { self.store.showMonth(offset: 1) }
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

    private func chevron(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                .frame(width: 26, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var dayList: some View {
        let events = CalendarStore.events(on: self.store.selectedDay, in: self.store.monthEvents)
        return VStack(alignment: .leading, spacing: 8) {
            Text(self.dayTitle(self.store.selectedDay))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            if events.isEmpty {
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
            ForEach(events) { event in EventRow(event: event, now: self.store.now, day: self.store.selectedDay) }
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
    @State private var hovering = false

    var body: some View {
        let live = self.event.start <= self.now && self.event.end > self.now
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(self.event.color).frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(self.event.title).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                Text(self.timeText).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
            Spacer(minLength: 6)
            if self.hovering, self.event.joinURL != nil || self.event.looksLikeMeeting {
                HStack(spacing: 6) {
                    if let url = self.event.joinURL { self.pill("Join", prominent: false) { NSWorkspace.shared.open(url) } }
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
            } else if live {
                Text("Now").font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(self.hovering ? 0.1 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .onHover { self.hovering = $0 }
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
