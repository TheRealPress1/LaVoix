@testable import FluidVoice_Debug
import Foundation
import XCTest

/// A meeting opened from the notch calendar: finding it in Google, inviting people, deleting it, what the notch shows meanwhile, and the card that
/// says a meeting was set. Nothing here reaches Google, EventKit or the real calendar: the requests are only built and the answers only read, and the
/// store is a sample one with made-up meetings.
final class CalendarMeetingDetailTests: XCTestCase {
    private let listJSON = Data(#"""
    {"items":[
      {"id":"e1","summary":"Sync","start":{"dateTime":"2027-01-15T09:00:00+01:00"},"hangoutLink":"https://meet.google.com/a-b-c","htmlLink":"https://g/e1","organizer":{"self":true},
       "attendees":[{"email":"Lea@X.com","displayName":"Léa","responseStatus":"accepted","organizer":true},{"email":"me@x.com","self":true,"responseStatus":"accepted"}]},
      {"id":"gone","status":"cancelled","summary":"Old"},
      {"id":"series","summary":"Weekly","recurrence":["RRULE:FREQ=WEEKLY"],"start":{"dateTime":"2027-01-15T09:00:00+01:00"}},
      {"id":"theirs","summary":"Theirs","organizer":{"email":"o@x.com"},"guestsCanInviteOthers":false,"start":{"dateTime":"2027-01-16T09:00:00Z"}}
    ]}
    """#.utf8)

    private func listed() throws -> [GoogleEventDetails] {
        try GoogleCalendarClient.parseList(status: 200, data: listJSON).get()
    }

    // MARK: Addresses

    func testQueryValuesReachGoogleAsTyped() {
        XCTAssertEqual(GoogleCalendarClient.encoded("a+b@x.com"), "a%2Bb@x.com", "a plus must not turn into a space")
        XCTAssertEqual(GoogleCalendarClient.findURL(iCalUID: "abc_1@google.com")?.absoluteString.contains("iCalUID=abc_1@google.com"), true)
        let window = GoogleCalendarClient.windowURL(start: Date(timeIntervalSince1970: 1_800_000_000), end: Date(timeIntervalSince1970: 1_800_003_600))?.absoluteString ?? ""
        XCTAssertTrue(window.contains("timeMin=2027-01-15T08%3A00%3A00Z"), window)
        XCTAssertTrue(window.contains("singleEvents=true"), "one entry per occurrence of a repeating meeting")
    }

    func testAChangeNamesTheMeetingAndOnlyAsksForWhatItNeeds() {
        XCTAssertEqual(GoogleCalendarClient.eventURL(id: "e1")?.absoluteString.hasSuffix("/events/e1"), true)
        XCTAssertEqual(GoogleCalendarClient.eventURL(id: "e1", query: "sendUpdates=all")?.absoluteString.hasSuffix("/events/e1?sendUpdates=all"), true)
    }

    // MARK: Reading Google's answers

    func testAListDropsCancelledMeetingsAndReadsGuestsAnswersAndTheMeetLink() throws {
        let found = try listed()
        XCTAssertEqual(found.map(\.id), ["e1", "series", "theirs"])
        let sync = found[0]
        XCTAssertEqual(sync.attendees.map(\.email), ["lea@x.com", "me@x.com"], "addresses are lower-cased")
        XCTAssertEqual(sync.attendees[0].status, "accepted")
        XCTAssertTrue(sync.attendees[0].isOrganizer)
        XCTAssertTrue(sync.attendees[1].isMe)
        XCTAssertEqual(sync.meetLink, "https://meet.google.com/a-b-c")
        XCTAssertEqual(sync.start, ISO8601DateFormatter().date(from: "2027-01-15T09:00:00+01:00"))
    }

    func testARepeatingMeetingIsKnownAsTheWholeSeries() throws {
        let found = try listed()
        XCTAssertTrue(found[1].isSeries)
        XCTAssertFalse(found[0].isSeries)
    }

    func testOnlyTheOrganizerOrAllowedGuestsMayInvite() throws {
        let found = try listed()
        XCTAssertTrue(found[0].canInviteOthers)
        XCTAssertFalse(found[2].isOrganizer)
        XCTAssertFalse(found[2].canInviteOthers)
    }

    func testTheMeetingOnScreenIsMatchedByTitleAndStart() throws {
        let found = try listed()
        let start = try XCTUnwrap(found[0].start)
        XCTAssertEqual(GoogleCalendarClient.match(found, title: " sync ", start: start.addingTimeInterval(30))?.id, "e1")
        XCTAssertNil(GoogleCalendarClient.match(found, title: "Sync", start: start.addingTimeInterval(300)), "five minutes off is another meeting")
        let untitled = GoogleEventDetails(id: "u", title: "", start: start, attendees: [], meetLink: nil, htmlLink: nil, isOrganizer: true, guestsCanInvite: true)
        XCTAssertEqual(GoogleCalendarClient.match([untitled], title: "Untitled", start: start)?.id, "u", "the notch calls a meeting with no title Untitled")
    }

    func testRefusalsAreReadInWords() {
        if case let .failure(f) = GoogleCalendarClient.parseEvent(status: 403, data: Data(#"{"error":{"message":"You need to be the organizer"}}"#.utf8)) {
            XCTAssertEqual(f.message, "You need to be the organizer")
        } else { XCTFail() }
        if case let .failure(f) = GoogleCalendarClient.parseEvent(status: 404, data: Data()) { XCTAssertTrue(f.message.contains("no longer find")) } else { XCTFail() }
        if case let .failure(f) = GoogleCalendarClient.parseList(status: 401, data: Data()) { XCTAssertTrue(f.message.contains("ran out")) } else { XCTFail() }
    }

    // MARK: Inviting

    func testInvitingAddsOnlyPeopleNotAlreadyInvitedAndSendsTheWholeListAgain() throws {
        let sync = try listed()[0]
        let everyone = GoogleCalendarClient.adding([GoogleAttendee(email: "New@x.com", name: "New"), GoogleAttendee(email: "lea@x.com")], to: sync.attendees)
        XCTAssertEqual(everyone.map(\.email), ["lea@x.com", "me@x.com", "New@x.com"])
        let sent = try XCTUnwrap(GoogleCalendarClient.guestListBody(everyone)["attendees"] as? [[String: Any]])
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(sent[0]["responseStatus"] as? String, "accepted", "an answer already given is kept")
        XCTAssertEqual(sent[0]["displayName"] as? String, "Léa")
        XCTAssertNil(sent[2]["responseStatus"], "a new guest has not answered")
    }

    // MARK: What the notch shows meanwhile

    @MainActor func testPeopleJustInvitedShowAtOnceAndNobodyTwice() {
        let store = CalendarStore.sample()
        let meeting = store.events[0]
        XCTAssertEqual(meeting.attendees.count, 4)
        let after = store.markInvited([CalendarStore.EventAttendee(name: "Zoé", email: "zoe@example.com"), CalendarStore.EventAttendee(name: "Again", email: "LEA@example.com")], to: meeting)
        XCTAssertEqual(after.attendees.count, 5, "Léa was already there")
        XCTAssertEqual(store.events[0].attendees.count, 5)
        XCTAssertEqual(store.monthEvents.first { $0.id == meeting.id }?.attendees.count, 5)
    }

    @MainActor func testADeletedMeetingLeavesAtOnceAndAMeetingMadeAgainIsNotHidden() {
        let store = CalendarStore.sample()
        let meeting = store.events[0]
        store.markDeleted(meeting)
        XCTAssertFalse(store.events.contains { $0.id == meeting.id })
        XCTAssertFalse(store.monthEvents.contains { $0.id == meeting.id })
        store.noteCreatedElsewhere(title: meeting.title, start: meeting.start, end: meeting.end, calendarID: nil, joinURL: nil)
        XCTAssertTrue(store.events.contains { $0.title == meeting.title }, "the same title at the same time, made again, is a new meeting")
    }

    // MARK: The card

    func testTheCardNamesTheDayAndSaysWhatWasDone() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let us = Locale(identifier: "en_US")
        let afternoon = DateComponents(calendar: utc, year: 2026, month: 11, day: 10, hour: 15, minute: 45).date!
        func line(_ days: Int) -> String {
            NotchBannerContent.MeetingSet.whenLine(start: afternoon.addingTimeInterval(Double(days) * 86400), end: afternoon.addingTimeInterval(Double(days) * 86400 + 1800), now: afternoon, calendar: utc, locale: us)
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }
        XCTAssertEqual(line(0), "Today · 3:45 PM – 4:15 PM")
        XCTAssertTrue(line(1).hasPrefix("Tomorrow · "))
        XCTAssertTrue(line(3).hasPrefix("Fri, Nov 13 · "))
        let link = URL(string: "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(NotchBannerContent.MeetingSet(title: "t", start: afternoon, end: afternoon, meetLink: link, invited: ["Martin D.", "Léa M.", "Manu G."], viaGoogle: true).detailLine, "Google Meet link ready · Invited Martin D., Léa M. +1")
        XCTAssertEqual(NotchBannerContent.MeetingSet(title: "t", start: afternoon, end: afternoon, meetLink: nil, invited: [], viaGoogle: false).detailLine, "Added to your calendar")
    }

    func testTheCardIsTallEnoughForItsButtons() {
        let set = NotchBannerContent.MeetingSet(title: "t", start: Date(), end: Date(), meetLink: nil, invited: [], viaGoogle: false)
        let card = NotchBannerContent(chatID: 0, chatGUID: "", title: "t", subtitle: nil, text: "", date: Date(), meetingSet: set)
        let message = NotchBannerContent(chatID: 1, chatGUID: "g", title: "t", subtitle: nil, text: "hi", date: Date())
        XCTAssertGreaterThan(card.contentHeight(expanded: false), message.contentHeight(expanded: false))
    }
}
