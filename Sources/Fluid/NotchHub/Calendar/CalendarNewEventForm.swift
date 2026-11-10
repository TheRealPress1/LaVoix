import AppKit
import SwiftUI

/// The "+" in the calendar tab: a small form on the right of the month for a new event. Save puts it in the Mac's Calendar (so it syncs to the account
/// of the calendar chosen), invites any guests, and it shows in the notch at once.
///
/// Three screens share the right-hand pane (it is only about 260 points wide): the form, a list of the accounts to save under (opened from the
/// avatar at the top right), and a guest search (opened from the guests row).
struct CalendarNewEventForm: View {
    enum Screen: Equatable { case form, accounts, guests }

    @ObservedObject var store: CalendarStore
    var staticLayout = false
    var initialTitle = ""
    /// Guests the search offers in a preview (the real search reads people and contacts, which a preview must not).
    var previewSuggestions: [CalendarGuest] = []
    let onDone: () -> Void

    @State private var screen: Screen
    @State private var title: String
    @State private var start: Date
    @State private var minutes = CalendarStore.newEventDefaultMinutes
    @State private var calendarID: String?
    @State private var guests: [CalendarGuest]
    @State private var guestQuery = ""
    @State private var suggestions: [CalendarGuest] = []
    @State private var problem: String?
    /// True once the event is saved: a failure after that (the guests) must not make Save create it a second time.
    @State private var saved = false
    @State private var working = false
    @FocusState private var focus: Field?

    private enum Field { case title, guest }

    init(
        store: CalendarStore, day: Date, staticLayout: Bool = false, initialTitle: String = "", screen: Screen = .form,
        guests: [CalendarGuest] = [], guestQuery: String = "", previewSuggestions: [CalendarGuest] = [], onDone: @escaping () -> Void
    ) {
        self._store = ObservedObject(wrappedValue: store)
        self.staticLayout = staticLayout
        self.initialTitle = initialTitle
        self.previewSuggestions = previewSuggestions
        self.onDone = onDone
        self._screen = State(initialValue: screen)
        self._title = State(initialValue: initialTitle)
        self._start = State(initialValue: CalendarStore.defaultStart(on: day, now: Date()))
        self._calendarID = State(initialValue: store.preferredNewEventCalendarID())
        self._guests = State(initialValue: guests)
        self._guestQuery = State(initialValue: guestQuery)
        self._suggestions = State(initialValue: previewSuggestions)
    }

    var body: some View {
        // The right-hand pane of the notch is only about 260 points wide and 190 high: nothing here may be bigger than that.
        VStack(alignment: .leading, spacing: 6) {
            switch self.screen {
            case .form: self.formScreen
            case .accounts: self.accountsScreen
            case .guests: self.guestsScreen
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            self.store.loadIdentityIfNeeded()
            guard !self.staticLayout else { return }
            DispatchQueue.main.async { self.focus = .title }
        }
        .onChange(of: self.focus) { _, focus in if focus != nil { NotchHubController.shared.beginTextEntry() } }
        .onChange(of: self.guestQuery) { _, _ in self.refreshSuggestions() }
    }

    // MARK: - The form

    private var formScreen: some View {
        Group {
            HStack(spacing: 8) {
                Text("New event").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                Spacer(minLength: 0)
                Button { self.screen = .accounts } label: { self.avatar(size: 26, ring: self.store.color(ofCalendar: self.effectiveCalendarID)) }
                    .buttonStyle(.plain)
                    .help(self.accountHelp)
                    .accessibilityLabel("Save in another account")
            }
            .frame(height: 26)
            self.titleField
            HStack(spacing: 6) {
                self.stepper(value: self.dayText, width: 62, help: "Another day", back: { self.start = CalendarStore.shifted(self.start, byDays: -1) }, forward: { self.start = CalendarStore.shifted(self.start, byDays: 1) })
                Spacer(minLength: 0)
                self.stepper(value: self.start.formatted(date: .omitted, time: .shortened), width: 58, help: "15 minutes earlier or later", back: { self.start = CalendarStore.shifted(self.start, byMinutes: -15) }, forward: { self.start = CalendarStore.shifted(self.start, byMinutes: 15) })
            }
            self.lengths
            self.guestsRow
            HStack(spacing: 10) {
                Button(self.saved ? "Close" : (self.working ? "Saving…" : "Save")) { self.save() }.buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 16).frame(height: 28)
                    .background(Capsule().fill(Color.white.opacity(self.working ? 0.6 : 1)))
                    .disabled(self.working)
                if !self.saved {
                    Button("Cancel") { self.cancel() }.buttonStyle(.plain)
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
                if let problem = self.problem {
                    Text(problem).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("until \(self.start.addingTimeInterval(Double(self.minutes) * 60).formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
            }
        }
    }

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
                    .focused(self.$focus, equals: .title)
                    .onSubmit { self.save() }
                    .onExitCommand { self.cancel() }
            }
        }
        .font(.system(size: 13.5, weight: .medium))
        .padding(.horizontal, 10).frame(height: 30)
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

    /// One line that says who is invited and opens the guest search.
    private var guestsRow: some View {
        Button {
            self.screen = .guests
            if !self.staticLayout { DispatchQueue.main.async { self.focus = .guest } }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.badge.plus").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                Text(Self.summary(of: self.guests))
                    .font(.system(size: 12.5, weight: self.guests.isEmpty ? .regular : .medium))
                    .foregroundStyle(self.guests.isEmpty ? Color.white.opacity(0.45) : Color.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Invite people")
    }

    /// "Add guests", "Martin B.", "Martin B., Léa D." or "Martin B., Léa D. +2".
    nonisolated static func summary(of guests: [CalendarGuest]) -> String {
        guard !guests.isEmpty else { return "Add guests" }
        let names = guests.prefix(2).map(\.display)
        return names.joined(separator: ", ") + (guests.count > 2 ? " +\(guests.count - 2)" : "")
    }

    // MARK: - Accounts

    private var effectiveCalendarID: String? {
        self.store.writableCalendars.first { $0.id == self.calendarID }?.id ?? self.store.preferredNewEventCalendarID()
    }

    private var accountHelp: String {
        guard let target = self.store.saveTargets().first(where: { $0.id == self.effectiveCalendarID }) else { return "No calendar takes new events" }
        return "Saves in \(target.primary) (\(target.calendarTitle)). Click to choose another."
    }

    /// You, in a circle: the photo on your Me card, or your initials, with a ring in the calendar's colour.
    private func avatar(size: CGFloat, ring: Color) -> some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.14))
            if let photo = self.store.me?.photo {
                Image(nsImage: photo).resizable().scaledToFill()
            } else {
                Text(self.store.me?.initials.isEmpty == false ? (self.store.me?.initials ?? "") : "•")
                    .font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(ring, lineWidth: 2))
        .contentShape(Circle())
    }

    private var accountsScreen: some View {
        let targets = self.store.saveTargets()
        return Group {
            self.subHeader("Save in", back: { self.screen = .form })
            if targets.isEmpty {
                Text("No calendar takes new events").font(.system(size: 12)).foregroundStyle(.orange)
            } else {
                self.scrolling {
                    VStack(spacing: 4) {
                        ForEach(targets) { target in
                            Button {
                                self.calendarID = target.id
                                self.screen = .form
                            } label: {
                                HStack(spacing: 8) {
                                    self.avatar(size: 24, ring: self.store.color(ofCalendar: target.id))
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(target.primary).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                        Text(target.secondary).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    if target.id == self.effectiveCalendarID {
                                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                                    }
                                }
                                .padding(.horizontal, 8).frame(height: 36)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(target.id == self.effectiveCalendarID ? 0.14 : 0.06)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Guests

    private var guestsScreen: some View {
        Group {
            self.subHeader("Guests", doneTitle: "Done", back: { self.finishGuests() })
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                if self.staticLayout {
                    Text(self.guestQuery.isEmpty ? "Name or email" : self.guestQuery)
                        .foregroundStyle(self.guestQuery.isEmpty ? Color.white.opacity(0.45) : Color.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("", text: self.$guestQuery, prompt: Text("Name or email").foregroundStyle(.white.opacity(0.45)))
                        .textFieldStyle(.plain)
                        .foregroundStyle(.white)
                        .tint(.white)
                        .focused(self.$focus, equals: .guest)
                        .onSubmit { self.submitGuestQuery() }
                        .onExitCommand { self.finishGuests() }
                }
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
            if !self.guests.isEmpty { self.guestChips }
            self.scrolling {
                VStack(spacing: 3) {
                    ForEach(self.suggestions) { guest in
                        Button { self.add(guest) } label: {
                            HStack(spacing: 8) {
                                self.initialsCircle(guest.initials, size: 24)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(guest.display).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                    if guest.display != guest.email {
                                        Text(guest.email).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8).frame(height: 34)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if self.suggestions.isEmpty, !self.guestQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("No one found. Type a full address to add it.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                    }
                }
            }
        }
    }

    private var guestChips: some View {
        self.scrolling(.horizontal) {
            HStack(spacing: 4) {
                ForEach(self.guests) { guest in
                    Button { self.guests.removeAll { $0 == guest } } label: {
                        HStack(spacing: 4) {
                            Text(guest.display).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                        }
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Capsule().fill(Color.white.opacity(0.16)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(guest.email)")
                }
            }
        }
        .frame(height: 22)
    }

    /// `content` in a scroll view, except in a preview picture, which cannot draw scroll views (the day list does the same).
    @ViewBuilder private func scrolling<Content: View>(_ axis: Axis.Set = .vertical, @ViewBuilder _ content: () -> Content) -> some View {
        if self.staticLayout { content() } else { ScrollView(axis, showsIndicators: false) { content() } }
    }

    private func initialsCircle(_ text: String, size: CGFloat) -> some View {
        Text(text.isEmpty ? "•" : text).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            .frame(width: size, height: size).background(Circle().fill(Color.white.opacity(0.14)))
    }

    private func subHeader(_ title: String, doneTitle: String? = nil, back: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            if doneTitle == nil {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                        .frame(width: 24, height: 24).background(Circle().fill(Color.white.opacity(0.1))).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
            Spacer(minLength: 0)
            if let doneTitle {
                Button(doneTitle, action: back).buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 12).frame(height: 24).background(Capsule().fill(Color.white))
            }
        }
        .frame(height: 26)
    }

    // MARK: - Actions

    nonisolated static func label(minutes: Int) -> String {
        minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m"
    }

    private func add(_ guest: CalendarGuest) {
        guard !self.guests.contains(where: { $0.email == guest.email }) else { return }
        self.guests.append(guest)
        self.guestQuery = ""
        self.suggestions = []
    }

    /// Return in the search: add the first match; with nothing typed, go back to the form.
    private func submitGuestQuery() {
        if self.guestQuery.trimmingCharacters(in: .whitespaces).isEmpty { self.finishGuests(); return }
        if let first = self.suggestions.first { self.add(first) }
    }

    private func finishGuests() {
        self.guestQuery = ""
        self.suggestions = []
        self.screen = .form
        if !self.staticLayout { DispatchQueue.main.async { self.focus = .title } }
    }

    /// Looks for people as you type, off the main thread; an answer that comes after the typing moved on is dropped.
    private func refreshSuggestions() {
        guard !self.staticLayout else { return }
        let query = self.guestQuery
        let taken = Set(self.guests.map(\.email))
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { self.suggestions = []; return }
        Task {
            let found = await Task.detached(priority: .userInitiated) { CalendarGuestDirectory.suggestions(for: query, excluding: taken) }.value
            if self.guestQuery == query { self.suggestions = found }
        }
    }

    private func save() {
        if self.saved { self.finish(); return }
        guard !self.working else { return }
        do {
            try self.store.createEvent(title: self.title, start: self.start, minutes: self.minutes, calendarID: self.effectiveCalendarID)
            if let id = self.effectiveCalendarID { self.store.rememberNewEventCalendar(id) }
            // Show the day the event is on, so it is seen where it landed.
            self.store.reveal(day: self.start)
            self.saved = true
        } catch {
            self.problem = error.localizedDescription
            return
        }
        guard !self.guests.isEmpty, !self.staticLayout else { self.finish(); return }
        self.invite()
    }

    /// The event is saved; now the guests (the Calendar app adds them and the account sends the invitations).
    private func invite() {
        guard let calendarID = self.effectiveCalendarID else { self.finish(); return }
        self.working = true
        self.problem = nil
        let guests = self.guests, title = CalendarStore.cleanTitle(self.title), start = self.start
        Task {
            let result = await CalendarInvites.addGuests(guests, calendarIdentifier: calendarID, title: title, start: start)
            self.working = false
            switch result {
            case .success: self.finish()
            case let .failure(failure): self.problem = "Saved, but the guests were not added: \(failure.message)"
            }
        }
    }

    private func cancel() { self.finish() }

    private func finish() {
        self.focus = nil
        if !self.staticLayout { NotchHubController.shared.endTextEntry() }
        self.onDone()
    }
}
