import AppKit
import SwiftUI

/// The "+" in the calendar tab: a small form on the right of the month for a new event. Save puts it in the Mac's Calendar (so it syncs to the account
/// of the calendar chosen) and it shows in the notch at once.
struct CalendarNewEventForm: View {
    @ObservedObject var store: CalendarStore
    var staticLayout = false
    var initialTitle = ""
    let onDone: () -> Void

    @State private var title: String
    @State private var start: Date
    @State private var minutes = CalendarStore.newEventDefaultMinutes
    @State private var calendarID: String?
    @State private var problem: String?
    @FocusState private var focused: Bool

    init(store: CalendarStore, day: Date, staticLayout: Bool = false, initialTitle: String = "", onDone: @escaping () -> Void) {
        self._store = ObservedObject(wrappedValue: store)
        self.staticLayout = staticLayout
        self.initialTitle = initialTitle
        self.onDone = onDone
        self._title = State(initialValue: initialTitle)
        self._start = State(initialValue: CalendarStore.defaultStart(on: day, now: Date()))
        self._calendarID = State(initialValue: store.preferredNewEventCalendarID())
    }

    var body: some View {
        // The right-hand pane of the notch is only about 260 points wide, so nothing here may be wider than that.
        VStack(alignment: .leading, spacing: 8) {
            self.titleField
            HStack(spacing: 6) {
                self.stepper(value: self.dayText, width: 62, help: "Another day", back: { self.start = CalendarStore.shifted(self.start, byDays: -1) }, forward: { self.start = CalendarStore.shifted(self.start, byDays: 1) })
                Spacer(minLength: 0)
                self.stepper(value: self.start.formatted(date: .omitted, time: .shortened), width: 58, help: "15 minutes earlier or later", back: { self.start = CalendarStore.shifted(self.start, byMinutes: -15) }, forward: { self.start = CalendarStore.shifted(self.start, byMinutes: 15) })
            }
            self.lengths
            self.calendarChoice
            HStack(spacing: 10) {
                Button("Save") { self.save() }.buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 16).frame(height: 28)
                    .background(Capsule().fill(Color.white))
                Button("Cancel") { self.cancel() }.buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                if let problem = self.problem {
                    Text(problem).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("until \(self.start.addingTimeInterval(Double(self.minutes) * 60).formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            guard !self.staticLayout else { return }
            DispatchQueue.main.async { self.focused = true }
        }
        .onChange(of: self.focused) { _, focused in if focused { NotchHubController.shared.beginTextEntry() } }
    }

    // MARK: - Pieces

    private var titleField: some View {
        Group {
            if self.staticLayout {
                Text(self.title.isEmpty ? "Title, e.g. Call with Martin" : self.title)
                    .foregroundStyle(self.title.isEmpty ? Color.white.opacity(0.45) : Color.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: self.$title, prompt: Text("Title, e.g. Call with Martin").foregroundStyle(.white.opacity(0.45)))
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .tint(.white)
                    .focused(self.$focused)
                    .onSubmit { self.save() }
                    .onExitCommand { self.cancel() }
            }
        }
        .font(.system(size: 13.5, weight: .medium))
        .padding(.horizontal, 10).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
    }

    private var dayText: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self.start) { return "Today" }
        if calendar.isDateInTomorrow(self.start) { return "Tomorrow" }
        return self.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private func stepper(value: String, width: CGFloat, help: String, back: @escaping () -> Void, forward: @escaping () -> Void) -> some View {
        HStack(spacing: 3) {
            self.arrow("chevron.left", help: help, action: back)
            Text(value).font(.system(size: 12.5, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8).frame(width: width)
            self.arrow("chevron.right", help: help, action: forward)
        }
    }

    private func arrow(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var lengths: some View {
        HStack(spacing: 4) {
            ForEach(CalendarStore.newEventLengths, id: \.self) { length in
                Button { self.minutes = length } label: {
                    Text(Self.label(minutes: length)).font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 24)
                        .background(Capsule().fill(Color.white.opacity(self.minutes == length ? 0.26 : 0.08)))
                        .foregroundStyle(self.minutes == length ? Color.white : Color.white.opacity(0.65))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var calendarChoice: some View {
        let writable = self.store.writableCalendars
        let chosen = writable.first { $0.id == self.calendarID } ?? writable.first
        return HStack(spacing: 6) {
            Text("Saves in").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            if let chosen {
                Button { self.cycleCalendar(in: writable, from: chosen) } label: {
                    HStack(spacing: 5) {
                        Circle().fill(chosen.color).frame(width: 8, height: 8)
                        Text(chosen.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(chosen.account).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                        if writable.count > 1 { Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.45)) }
                    }
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(writable.count > 1 ? "Click for the next calendar" : "The only calendar that takes new events")
            } else {
                Text("No calendar takes new events").font(.system(size: 12)).foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Actions

    nonisolated static func label(minutes: Int) -> String {
        minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m"
    }

    private func cycleCalendar(in writable: [CalendarStore.CalendarInfo], from current: CalendarStore.CalendarInfo) {
        guard let index = writable.firstIndex(of: current), !writable.isEmpty else { return }
        self.calendarID = writable[(index + 1) % writable.count].id
    }

    private func save() {
        do {
            try self.store.createEvent(title: self.title, start: self.start, minutes: self.minutes, calendarID: self.calendarID)
            if let id = self.calendarID { self.store.rememberNewEventCalendar(id) }
            // Show the day the event is on, so it is seen where it landed.
            self.store.reveal(day: self.start)
            self.finish()
        } catch {
            self.problem = error.localizedDescription
        }
    }

    private func cancel() { self.finish() }

    private func finish() {
        self.focused = false
        if !self.staticLayout { NotchHubController.shared.endTextEntry() }
        self.onDone()
    }
}
