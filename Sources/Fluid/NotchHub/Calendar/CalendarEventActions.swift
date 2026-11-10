import Foundation

/// What the meeting detail screen does to a meeting that exists: look it up in Google, invite more people, delete it. The Google route is used whenever
/// the meeting's account allowed calendar events in myOS (a token was handed over); a delete falls back to the Mac's Calendar app, which syncs it.
@MainActor
enum CalendarEventActions {
    struct Failure: Error, Equatable { let message: String }

    static let guestsNeedGoogle = "Guests need Google. Allow calendar events for this account in myOS (Mail, or Connections in the notch), then try again."

    /// Whether this meeting can be changed through Google right now.
    static func hasGoogle(_ event: CalendarStore.Event, store: CalendarStore) -> Bool {
        store.googleAccess(for: event) != nil
    }

    /// Google's record of the meeting (its id, who is invited, its Meet link), or nil when the account has not allowed it or Google does not have it in
    /// the primary calendar. Never throws: the detail screen still works from what the Mac's Calendar says.
    static func lookUp(_ event: CalendarStore.Event, store: CalendarStore) async -> GoogleEventDetails? {
        guard let access = store.googleAccess(for: event) else { return nil }
        let result = await GoogleCalendarClient.find(
            id: event.googleID, iCalUID: event.externalID, title: event.title, start: event.start, end: event.end, token: access.token
        )
        switch result {
        case let .success(found):
            DebugLogger.shared.info("Calendar: Google \(found == nil ? "has no such meeting in the primary calendar" : "found the meeting")", source: "Calendar")
            return found
        case let .failure(failure):
            DebugLogger.shared.info("Calendar: looking the meeting up in Google failed: \(failure.message)", source: "Calendar")
            return nil
        }
    }

    /// Invites people through Google (it sends them the invitation) and returns the meeting, and Google's record of it, with them on it.
    static func addGuests(_ guests: [CalendarGuest], to event: CalendarStore.Event, details: GoogleEventDetails?, store: CalendarStore) async -> Result<(event: CalendarStore.Event, details: GoogleEventDetails), Failure> {
        guard let access = store.googleAccess(for: event) else { return .failure(Failure(message: self.guestsNeedGoogle)) }
        var known = details
        if known == nil { known = await self.lookUp(event, store: store) }
        guard let known else {
            return .failure(Failure(message: "Google does not have this meeting in your main calendar, so people cannot be invited from here."))
        }
        guard known.canInviteOthers else { return .failure(Failure(message: "Only the person who organizes this meeting can invite others.")) }
        let new = guests.map { GoogleAttendee(email: $0.email, name: $0.name) }
        switch await GoogleCalendarClient.addGuests(new, to: known, token: access.token) {
        case let .success(updated):
            DebugLogger.shared.info("Calendar: invited \(guests.count) \(guests.count == 1 ? "person" : "people") through Google", source: "Calendar")
            let people = guests.map { CalendarStore.EventAttendee(name: $0.name, email: $0.email) }
            return .success((store.markInvited(people, to: event), updated))
        case let .failure(failure):
            return .failure(Failure(message: failure.message))
        }
    }

    /// Deletes the meeting: through Google when the account allows it (the guests are told it is cancelled), else from the Mac's Calendar app.
    static func delete(_ event: CalendarStore.Event, details: GoogleEventDetails?, store: CalendarStore) async -> Result<Void, Failure> {
        if let access = store.googleAccess(for: event) {
            var known = details
            if known == nil { known = await self.lookUp(event, store: store) }
            if let known {
                switch await GoogleCalendarClient.delete(id: known.id, token: access.token) {
                case .success:
                    DebugLogger.shared.info("Calendar: a meeting was deleted through Google", source: "Calendar")
                    store.markDeleted(event)
                    return .success(())
                case let .failure(failure):
                    // The Mac's Calendar can still delete it (and sync that), unless the meeting is not in it.
                    DebugLogger.shared.info("Calendar: deleting through Google failed (\(failure.message)); trying the Calendar app", source: "Calendar")
                    guard event.ekIdentifier != nil, event.canModify else { return .failure(Failure(message: failure.message)) }
                }
            }
        }
        guard event.canModify else { return .failure(Failure(message: CalendarChangeError.readOnly.localizedDescription)) }
        do {
            try store.removeFromCalendarApp(event)
            DebugLogger.shared.info("Calendar: a meeting was deleted in the Calendar app", source: "Calendar")
            return .success(())
        } catch {
            return .failure(Failure(message: error.localizedDescription))
        }
    }
}
