@testable import FluidVoice_Debug
import Foundation
import XCTest

/// The arrows on the notch calendar move one day at a time; the month grid only changes when the day leaves it.
final class CalendarDayStepTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        c.firstWeekday = 1
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        self.calendar.date(from: DateComponents(year: y, month: m, day: d)) ?? Date()
    }

    func testTheNextArrowMovesOneDayAndKeepsTheMonth() throws {
        let step = try XCTUnwrap(CalendarStore.step(selected: self.date(2026, 11, 7), displayedMonth: self.date(2026, 11, 1), byDays: 1, calendar: self.calendar))
        XCTAssertEqual(step.day, self.date(2026, 11, 8))
        XCTAssertEqual(step.month, self.date(2026, 11, 1), "the month grid stays put while the day is inside it")
    }

    func testThePreviousArrowMovesOneDayBack() throws {
        let step = try XCTUnwrap(CalendarStore.step(selected: self.date(2026, 11, 7), displayedMonth: self.date(2026, 11, 1), byDays: -1, calendar: self.calendar))
        XCTAssertEqual(step.day, self.date(2026, 11, 6))
        XCTAssertEqual(step.month, self.date(2026, 11, 1))
    }

    func testStepsAcrossTheEndOfAMonthTakeTheGridAlong() throws {
        let forward = try XCTUnwrap(CalendarStore.step(selected: self.date(2026, 11, 30), displayedMonth: self.date(2026, 11, 1), byDays: 1, calendar: self.calendar))
        XCTAssertEqual(forward.day, self.date(2026, 12, 1))
        XCTAssertEqual(forward.month, self.date(2026, 12, 1))
        let back = try XCTUnwrap(CalendarStore.step(selected: self.date(2026, 12, 1), displayedMonth: self.date(2026, 12, 1), byDays: -1, calendar: self.calendar))
        XCTAssertEqual(back.day, self.date(2026, 11, 30))
        XCTAssertEqual(back.month, self.date(2026, 11, 1))
    }

    func testAcrossTheYearAndTheLeapDay() throws {
        let year = try XCTUnwrap(CalendarStore.step(selected: self.date(2026, 12, 31), displayedMonth: self.date(2026, 12, 1), byDays: 1, calendar: self.calendar))
        XCTAssertEqual(year.day, self.date(2027, 1, 1))
        XCTAssertEqual(year.month, self.date(2027, 1, 1))
        let leap = try XCTUnwrap(CalendarStore.step(selected: self.date(2028, 2, 28), displayedMonth: self.date(2028, 2, 1), byDays: 1, calendar: self.calendar))
        XCTAssertEqual(leap.day, self.date(2028, 2, 29))
        XCTAssertEqual(leap.month, self.date(2028, 2, 1))
    }

    func testADayChosenOnAFadedNeighbourDayCorrectsTheGridOnTheNextStep() throws {
        // Nov 2026's grid shows Dec 1 to 5 faded. Choosing Dec 3 there and pressing next lands on Dec 4 with December on the grid.
        let step = try XCTUnwrap(CalendarStore.step(selected: self.date(2026, 12, 3), displayedMonth: self.date(2026, 11, 1), byDays: 1, calendar: self.calendar))
        XCTAssertEqual(step.day, self.date(2026, 12, 4))
        XCTAssertEqual(step.month, self.date(2026, 12, 1))
    }
}
