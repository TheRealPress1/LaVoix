import AppKit
import SwiftUI

/// The next meeting with Join and Record buttons, and the rest of today and tomorrow.
struct CalendarWidgetView: View {
    @ObservedObject var store: CalendarStore
    var staticLayout = false

    var body: some View {
        Group {
            switch self.store.access {
            case .granted: self.agenda
            case .unknown: self.permissionCard(denied: false)
            case .denied: self.permissionCard(denied: true)
            }
        }
        .foregroundStyle(.white)
        .onAppear { if !self.staticLayout { self.store.reload() } }
    }

    private var agenda: some View {
        let featured = CalendarStore.featured(from: self.store.events, now: self.store.now)
        let others = self.store.events.filter { $0.id != featured?.id }
        return HStack(alignment: .top, spacing: 18) {
            Group {
                if let featured {
                    self.featuredCard(featured)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "calendar").font(.system(size: 26, weight: .light)).foregroundStyle(.white.opacity(0.4))
                        Text("Nothing coming up").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 270)

            VStack(alignment: .leading, spacing: 6) {
                Text("Later")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .textCase(.uppercase)
                if others.isEmpty {
                    Text("Nothing else scheduled").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                } else if self.staticLayout {
                    self.rows(Array(others.prefix(4)))
                } else {
                    ScrollView(.vertical, showsIndicators: false) { self.rows(others) }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func rows(_ events: [CalendarStore.Event]) -> some View {
        VStack(spacing: 4) {
            ForEach(events) { event in
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 2).fill(event.color).frame(width: 3, height: 22)
                    Text(event.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(self.dayAndTime(event))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                .padding(.horizontal, 9)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
            }
        }
    }

    private func dayAndTime(_ event: CalendarStore.Event) -> String {
        if event.isAllDay { return "All day" }
        let time = event.start.formatted(date: .omitted, time: .shortened)
        return Calendar.current.isDateInToday(event.start) ? time : "Tomorrow \(time)"
    }

    private func featuredCard(_ event: CalendarStore.Event) -> some View {
        let live = event.start <= self.store.now
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(event.color).frame(width: 8, height: 8)
                Text(CalendarStore.whenLabel(start: event.start, end: event.end, now: self.store.now))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(live ? Color.green : .white.opacity(0.7))
            }
            Text(event.title).font(.system(size: 18, weight: .semibold)).lineLimit(2)
            Text(self.timeRange(event) + (event.location.map { " · \($0)" } ?? ""))
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if let url = event.joinURL {
                    self.pill("Join", prominent: true) { NSWorkspace.shared.open(url) }
                }
                self.pill("Record", prominent: event.joinURL == nil) {
                    NotchMeetingCardController.shared.record(event)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.08)))
    }

    private func timeRange(_ event: CalendarStore.Event) -> String {
        "\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))"
    }

    private func permissionCard(denied: Bool) -> some View {
        HStack(spacing: 18) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 30, weight: .light)).foregroundStyle(.white.opacity(0.7))
            VStack(alignment: .leading, spacing: 6) {
                Text("Allow LaVoix to see your calendar").font(.system(size: 15, weight: .semibold))
                Text("Your next meeting shows up here, and LaVoix can offer to record it when it starts. Events are read on this Mac and never leave it.")
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
}
