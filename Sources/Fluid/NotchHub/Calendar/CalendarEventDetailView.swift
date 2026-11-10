import AppKit
import SwiftUI

/// A meeting opened from the day list, in the same right-hand pane (about 260 x 190 points): when and where it is, a Join and a Record button, who is
/// invited (with a button to invite more people), and a bin to delete it.
///
/// Inviting people and a delete that tells the guests go through Google (the account allowed calendar events in myOS); the Mac's Calendar can do
/// neither for guests. A meeting in an account that has not allowed it can still be deleted: that goes through the Calendar app.
struct CalendarEventDetailView: View {
    enum Screen: Equatable { case detail, guests }

    @ObservedObject var store: CalendarStore
    var staticLayout = false
    let onClose: () -> Void

    @State private var event: CalendarStore.Event
    @State private var details: GoogleEventDetails?
    @State private var screen: Screen
    @State private var newGuests: [CalendarGuest]
    @State private var confirmingDelete: Bool
    @State private var working: String?
    @State private var message: Message?
    private let previewQuery: String
    private let previewSuggestions: [CalendarGuest]

    struct Message: Equatable {
        let text: String
        let good: Bool
    }

    init(
        store: CalendarStore, event: CalendarStore.Event, staticLayout: Bool = false, screen: Screen = .detail, confirmingDelete: Bool = false,
        newGuests: [CalendarGuest] = [], previewQuery: String = "", previewSuggestions: [CalendarGuest] = [], onClose: @escaping () -> Void
    ) {
        self._store = ObservedObject(wrappedValue: store)
        self.staticLayout = staticLayout
        self.onClose = onClose
        self._event = State(initialValue: event)
        self._screen = State(initialValue: screen)
        self._confirmingDelete = State(initialValue: confirmingDelete)
        self._newGuests = State(initialValue: newGuests)
        self.previewQuery = previewQuery
        self.previewSuggestions = previewSuggestions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch self.screen {
            case .detail: self.detailScreen
            case .guests:
                CalendarGuestPicker(
                    guests: self.$newGuests, title: "Invite", alreadyInvited: Set(self.event.attendees.map { $0.email.lowercased() }),
                    staticLayout: self.staticLayout, previewQuery: self.previewQuery, previewSuggestions: self.previewSuggestions, escapeCancels: true
                ) { self.finishInviting() }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await self.loadGoogle() }
    }

    // MARK: - The meeting

    private var detailScreen: some View {
        Group {
            self.header
            if self.confirmingDelete {
                self.deleteConfirmation
            } else {
                self.whenAndWhere
                self.buttons
                self.guestsSection
                self.messageLine
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { self.onClose() } label: {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                    .frame(width: 24, height: 24).background(Circle().fill(Color.white.opacity(0.1))).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to the day")
            Text(self.event.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            Spacer(minLength: 0)
            if self.event.canModify, !self.confirmingDelete {
                Button { self.message = nil; self.confirmingDelete = true } label: {
                    Image(systemName: "trash").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                        .frame(width: 24, height: 24).background(Circle().fill(Color.white.opacity(0.1))).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Delete this meeting")
                .accessibilityLabel("Delete this meeting")
            }
        }
        .frame(height: 26)
    }

    private var whenAndWhere: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(self.whenText).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            HStack(spacing: 5) {
                Circle().fill(self.event.color).frame(width: 7, height: 7)
                Text(self.whereText).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
        }
    }

    private var whenText: String {
        if self.event.isAllDay { return "All day · " + self.event.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
        return NotchBannerContent.MeetingSet.whenLine(start: self.event.start, end: self.event.end)
    }

    /// The place when there is one, then the calendar and the account it is in.
    private var whereText: String {
        var parts: [String] = []
        if let place = self.event.location, !place.isEmpty { parts.append(place) }
        let calendar = self.event.calendarTitle
        var account = calendar
        if let owner = self.store.ownerEmails[self.event.calendarID] {
            account = calendar.isEmpty || calendar.lowercased() == owner ? owner : "\(calendar) · \(owner)"
        }
        if !account.isEmpty { parts.append(account) }
        return parts.joined(separator: " · ")
    }

    private var meetURL: URL? { self.details?.meetLink.flatMap(URL.init(string:)) ?? self.event.joinURL }

    private var buttons: some View {
        HStack(spacing: 6) {
            if let url = self.meetURL { self.pill("Join", systemImage: "video.fill", prominent: true) { NSWorkspace.shared.open(url) } }
            if self.event.looksLikeMeeting || self.meetURL != nil {
                self.pill("Record", systemImage: "record.circle", prominent: false) { NotchMeetingCardController.shared.record(self.event) }
            }
            Spacer(minLength: 0)
        }
    }

    private func pill(_ title: String, systemImage: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 10.5, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(prominent ? Color.black : Color.white)
            .padding(.horizontal, 10).frame(height: 24)
            .background(Capsule().fill(prominent ? Color.white : Color.white.opacity(0.16)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Guests

    private var guestsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(self.event.attendees.isEmpty ? "Guests" : "Guests · \(self.event.attendees.count)")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 0)
                if self.event.canModify {
                    Button { self.startInviting() } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "person.badge.plus").font(.system(size: 10.5))
                            Text("Add").font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 9).frame(height: 22)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(self.working != nil)
                    .help("Invite more people")
                }
            }
            if self.event.attendees.isEmpty {
                Text("No one else is invited.").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.4))
            } else {
                CalendarPane.scrolling(staticLayout: self.staticLayout) {
                    VStack(spacing: 2) { ForEach(self.event.attendees) { self.guestRow($0) } }
                }
            }
        }
    }

    private func guestRow(_ guest: CalendarStore.EventAttendee) -> some View {
        HStack(spacing: 8) {
            CalendarPane.initialsCircle(guest.initials, size: 22)
            Text(guest.display).font(.system(size: 12, weight: .medium)).lineLimit(1)
            if guest.isOrganizer { Text("organizer").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)) }
            Spacer(minLength: 0)
            Self.statusIcon(guest.status)
        }
        .frame(height: 26)
        .help(guest.email)
    }

    @ViewBuilder private static func statusIcon(_ status: CalendarStore.EventAttendee.Status) -> some View {
        switch status {
        case .accepted: Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Color.green.opacity(0.85))
        case .declined: Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Color.red.opacity(0.8))
        case .tentative: Image(systemName: "questionmark.circle.fill").font(.system(size: 12)).foregroundStyle(Color.orange.opacity(0.85))
        case .pending: Image(systemName: "circle.dotted").font(.system(size: 12)).foregroundStyle(.white.opacity(0.35))
        }
    }

    @ViewBuilder private var messageLine: some View {
        if let working = self.working {
            Text(working).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
        } else if let message = self.message {
            Text(message.text).font(.system(size: 11)).foregroundStyle(message.good ? Color.green.opacity(0.9) : Color.orange)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Delete

    /// Who hears about it, in words that are true for this meeting.
    private var deleteNote: String {
        // Only claim the guests are told when Google says this account organizes the meeting.
        if let details = self.details {
            if !details.isOrganizer { return "It is taken off your calendar; the organizer keeps it." }
            if !self.event.attendees.isEmpty { return "Everyone invited is told it is cancelled." }
        }
        return "It is taken off your calendar."
    }

    private var deleteConfirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Delete \u{201C}\(self.event.title)\u{201D}?").font(.system(size: 13.5, weight: .semibold)).lineLimit(2)
            Text(self.deleteNote).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { self.delete() } label: {
                    Text(self.working == nil ? "Delete" : "Deleting…").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).frame(height: 28)
                        .background(Capsule().fill(Color(red: 0.86, green: 0.24, blue: 0.22).opacity(self.working == nil ? 1 : 0.6)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(self.working != nil)
                Button("Keep") { self.confirmingDelete = false }.buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                    .disabled(self.working != nil)
            }
            if let message = self.message, !message.good {
                Text(message.text).font(.system(size: 11)).foregroundStyle(Color.orange).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Actions

    /// Asks Google about the meeting (its id, who is invited with their answers, its Meet link). The screen already shows what the Calendar app knows.
    private func loadGoogle() async {
        guard !self.staticLayout, self.details == nil else { return }
        guard let found = await CalendarEventActions.lookUp(self.event, store: self.store) else { return }
        self.apply(found)
    }

    /// Google's record in place of the Calendar app's: it knows who answered what and who organizes the meeting.
    private func apply(_ found: GoogleEventDetails) {
        self.details = found
        self.event.googleID = found.id
        let people = found.attendees.filter { !$0.isMe && !$0.isResource }.map { person in
            CalendarStore.EventAttendee(name: person.name, email: person.email, status: Self.status(person.status), isOrganizer: person.isOrganizer)
        }
        if !people.isEmpty { self.event.attendees = people; self.event.attendeeCount = people.count }
        if self.event.joinURL == nil, let meet = found.meetLink.flatMap(URL.init(string:)) { self.event.joinURL = meet }
    }

    private static func status(_ google: String) -> CalendarStore.EventAttendee.Status {
        switch google {
        case "accepted": .accepted
        case "declined": .declined
        case "tentative": .tentative
        default: .pending
        }
    }

    private func startInviting() {
        self.message = nil
        guard CalendarEventActions.hasGoogle(self.event, store: self.store) || self.staticLayout else {
            self.message = Message(text: CalendarEventActions.guestsNeedGoogle, good: false)
            return
        }
        self.newGuests = []
        self.screen = .guests
    }

    /// Done in the guest search: invite whoever was chosen.
    private func finishInviting() {
        let chosen = self.newGuests
        self.newGuests = []
        self.screen = .detail
        guard !chosen.isEmpty, !self.staticLayout else { return }
        self.working = "Inviting \(chosen.map(\.display).prefix(2).joined(separator: ", "))\(chosen.count > 2 ? " +\(chosen.count - 2)" : "")…"
        self.message = nil
        Task {
            let result = await CalendarEventActions.addGuests(chosen, to: self.event, details: self.details, store: self.store)
            self.working = nil
            switch result {
            case let .success(done):
                self.event = done.event
                self.apply(done.details)
                self.message = Message(text: "Invited \(chosen.map(\.display).prefix(2).joined(separator: ", "))\(chosen.count > 2 ? " +\(chosen.count - 2)" : ""). Google sent the invitation.", good: true)
            case let .failure(failure):
                self.message = Message(text: failure.message, good: false)
            }
        }
    }

    private func delete() {
        guard self.working == nil, !self.staticLayout else { return }
        self.working = "Deleting…"
        self.message = nil
        Task {
            let result = await CalendarEventActions.delete(self.event, details: self.details, store: self.store)
            self.working = nil
            switch result {
            case .success: self.onClose()
            case let .failure(failure): self.message = Message(text: failure.message, good: false)
            }
        }
    }
}
