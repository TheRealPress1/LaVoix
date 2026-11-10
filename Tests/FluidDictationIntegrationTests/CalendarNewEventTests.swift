@testable import FluidVoice_Debug
import Foundation
import XCTest

/// The notch calendar's "+" (a new event saved in the Mac's Calendar): the rules for where an event starts and how it is named, and what the
/// store does with it. Nothing here touches EventKit or the real calendar: sample stores keep their made-up data, and a store that was never
/// given access refuses to save.
final class CalendarNewEventTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func clock(_ date: Date) -> String {
        let c = calendar.dateComponents([.day, .hour, .minute], from: date)
        return String(format: "%d %02d:%02d", c.day!, c.hour!, c.minute!)
    }

    // MARK: Where an event starts

    func testToday_startsAtTheNextQuarterHourAtLeastFiveMinutesAway() {
        let day = date(10, 0, 0)
        XCTAssertEqual(clock(CalendarStore.defaultStart(on: day, now: date(10, 10, 7), calendar: calendar)), "10 10:15")
        XCTAssertEqual(clock(CalendarStore.defaultStart(on: day, now: date(10, 10, 10), calendar: calendar)), "10 10:15", "exactly five minutes away is enough")
        XCTAssertEqual(clock(CalendarStore.defaultStart(on: day, now: date(10, 10, 11), calendar: calendar)), "10 10:30")
        XCTAssertEqual(clock(CalendarStore.defaultStart(on: day, now: date(10, 10, 0), calendar: calendar)), "10 10:15")
    }

    func testLateAtNight_staysOnTheSameDay() {
        let start = CalendarStore.defaultStart(on: date(10, 0, 0), now: date(10, 23, 50), calendar: calendar)
        XCTAssertEqual(clock(start), "10 23:45")
    }

    func testAnotherDay_startsAtNine() {
        XCTAssertEqual(clock(CalendarStore.defaultStart(on: date(12, 0, 0), now: date(10, 14, 20), calendar: calendar)), "12 09:00")
        XCTAssertEqual(clock(CalendarStore.defaultStart(on: date(8, 0, 0), now: date(10, 14, 20), calendar: calendar)), "8 09:00")
    }

    func testTheTimeStepsByQuarterHoursAndStaysInItsDay() {
        XCTAssertEqual(clock(CalendarStore.shifted(date(10, 10, 0), byMinutes: 15, calendar: calendar)), "10 10:15")
        XCTAssertEqual(clock(CalendarStore.shifted(date(10, 10, 0), byMinutes: -15, calendar: calendar)), "10 09:45")
        XCTAssertEqual(clock(CalendarStore.shifted(date(10, 23, 45), byMinutes: 15, calendar: calendar)), "10 23:45")
        XCTAssertEqual(clock(CalendarStore.shifted(date(10, 0, 0), byMinutes: -15, calendar: calendar)), "10 00:00")
    }

    func testTheDayStepsAndKeepsTheTime() {
        XCTAssertEqual(clock(CalendarStore.shifted(date(10, 15, 30), byDays: 1, calendar: calendar)), "11 15:30")
        XCTAssertEqual(clock(CalendarStore.shifted(date(10, 15, 30), byDays: -3, calendar: calendar)), "7 15:30")
    }

    // MARK: Naming

    func testTheTitleIsTrimmedKeptToOneLineAndNeverEmpty() {
        XCTAssertEqual(CalendarStore.cleanTitle("  Call with Martin \n"), "Call with Martin")
        XCTAssertEqual(CalendarStore.cleanTitle("Lunch\nwith Maya"), "Lunch with Maya")
        XCTAssertEqual(CalendarStore.cleanTitle("   "), "New event")
        XCTAssertEqual(CalendarStore.cleanTitle(""), "New event")
        XCTAssertEqual(CalendarStore.cleanTitle(String(repeating: "a", count: 500)).count, 200)
    }

    func testTheLengthsOfferedIncludeTheDefaultAndReadWell() {
        XCTAssertTrue(CalendarStore.newEventLengths.contains(CalendarStore.newEventDefaultMinutes))
        XCTAssertEqual(CalendarNewEventForm.label(minutes: 30), "30m")
        XCTAssertEqual(CalendarNewEventForm.label(minutes: 60), "1h")
        XCTAssertEqual(CalendarNewEventForm.label(minutes: 120), "2h")
    }

    // MARK: The store

    @MainActor func testASampleStoreKeepsTheNewEventInMemoryWithItsTimesAndCalendar() throws {
        let store = CalendarStore.sample()
        let start = Date().addingTimeInterval(3 * 3600)
        let event = try store.createEvent(title: "  Call with Martin ", start: start, minutes: 45, calendarID: "sample-work")
        XCTAssertEqual(event.title, "Call with Martin")
        XCTAssertEqual(event.end.timeIntervalSince(event.start), 45 * 60, accuracy: 1)
        XCTAssertEqual(event.calendarTitle, "Work")
        XCTAssertTrue(store.monthEvents.contains(event))
        XCTAssertTrue(store.events.contains(event))
    }

    @MainActor func testAStoreWithoutAccessRefusesToSave() {
        let store = CalendarStore()
        XCTAssertThrowsError(try store.createEvent(title: "x", start: Date(), minutes: 30, calendarID: nil)) { error in
            XCTAssertEqual(error as? CalendarWriteError, .noAccess)
        }
    }

    @MainActor func testOnlyCalendarsThatTakeEventsAreOffered() {
        let store = CalendarStore.sample()
        XCTAssertEqual(store.writableCalendars.map(\.id), ["sample-work", "sample-home"])
        UserDefaults.standard.removeObject(forKey: "LaVoixNotchCalendarNewEventCalendar")
        XCTAssertEqual(store.preferredNewEventCalendarID(), "sample-work")
        store.rememberNewEventCalendar("sample-home")
        XCTAssertEqual(store.preferredNewEventCalendarID(), "sample-home", "the calendar chosen last time comes first")
        UserDefaults.standard.removeObject(forKey: "LaVoixNotchCalendarNewEventCalendar")
    }

    @MainActor func testRevealingAnotherMonthTakesTheGridThere() {
        let store = CalendarStore.sample()
        let target = Calendar.current.date(byAdding: .month, value: 2, to: Date())!
        store.reveal(day: target)
        XCTAssertTrue(Calendar.current.isDate(store.selectedDay, inSameDayAs: target))
        XCTAssertTrue(Calendar.current.isDate(store.displayedMonth, equalTo: target, toGranularity: .month))
    }
}
