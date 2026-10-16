import XCTest
@testable import Pickup

final class PickupDateCalculatorTests: XCTestCase {
    let chicago = TimeZone(identifier: "America/Chicago")!
    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = chicago
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    func days(_ dates: [Date]) -> [String] { dates.map(PickupDateCalculator.apiDateString) }

    func testBeforeTwoAMIncludesToday() {
        // Thu 2026-09-17 01:30 CT
        XCTAssertEqual(days(PickupDateCalculator.availableDates(from: date(2026,9,17,1,30), count: 2)), ["2026-09-17", "2026-09-18"])
    }
    func testAfterTwoAMStartsTomorrow() {
        XCTAssertEqual(days(PickupDateCalculator.availableDates(from: date(2026,9,17,2,0), count: 1)), ["2026-09-18"])
    }
    func testSkipsSunday() {
        // Sat 2026-09-19 noon → Mon 21
        XCTAssertEqual(days(PickupDateCalculator.availableDates(from: date(2026,9,19), count: 2)), ["2026-09-21", "2026-09-22"])
    }
    func testSkipsThanksgivingAndObservedChristmas() {
        // Wed 2026-11-25 → Fri 27 (Thu 26 is Thanksgiving)
        XCTAssertEqual(days(PickupDateCalculator.availableDates(from: date(2026,11,25), count: 1)), ["2026-11-27"])
        // 2027-12-25 is a Saturday → observed Fri 24. From Thu 2027-12-23 noon → Mon 27.
        XCTAssertEqual(days(PickupDateCalculator.availableDates(from: date(2027,12,23), count: 1)), ["2027-12-27"])
    }
    func testObservedMondayWhenHolidayOnSunday() {
        // 2027-07-04 is Sunday → observed Mon Jul 5. From Sat Jul 3 noon → Tue Jul 6.
        XCTAssertEqual(days(PickupDateCalculator.availableDates(from: date(2027,7,3), count: 1)), ["2027-07-06"])
    }
    func testReturnsRequestedCount() {
        XCTAssertEqual(PickupDateCalculator.availableDates(from: date(2026,9,17), count: 6).count, 6)
    }
    func testLabels() {
        let d = PickupDateCalculator.availableDates(from: date(2026,9,17), count: 1)[0]   // Fri 2026-09-18
        XCTAssertEqual(PickupDateCalculator.displayLabel(d).weekday, "Fri")
        XCTAssertEqual(PickupDateCalculator.displayLabel(d).day, "18")
        XCTAssertEqual(PickupDateCalculator.longDisplay(d), "Friday, September 18, 2026")
    }
    func testIsHolidayFixedDatesAndObservedRules() {
        // New Year's Day
        XCTAssertTrue(PickupDateCalculator.isHoliday(date(2026,1,1)))
        // Independence Day 2027 falls on Sunday: both the actual date and its observed
        // Monday (July 5) are non-pickup days.
        XCTAssertTrue(PickupDateCalculator.isHoliday(date(2027,7,4)))
        XCTAssertTrue(PickupDateCalculator.isHoliday(date(2027,7,5)))
        // Christmas 2027 falls on Saturday: both the actual date and its observed
        // Friday (Dec 24) are non-pickup days.
        XCTAssertTrue(PickupDateCalculator.isHoliday(date(2027,12,25)))
        XCTAssertTrue(PickupDateCalculator.isHoliday(date(2027,12,24)))
        // Thanksgiving 2026 (4th Thu Nov) is Nov 26
        XCTAssertTrue(PickupDateCalculator.isHoliday(date(2026,11,26)))
        // A regular Wednesday is not a holiday
        XCTAssertFalse(PickupDateCalculator.isHoliday(date(2026,11,25)))
        // Juneteenth
        XCTAssertTrue(PickupDateCalculator.isHoliday(date(2026,6,19)))
        // Veterans Day
        XCTAssertTrue(PickupDateCalculator.isHoliday(date(2026,11,11)))
    }

    func testNewYearsOnSaturdayObservedPriorFriday() {
        // 2028-01-01 is a Saturday → observed Fri 2027-12-31. From Thu 2027-12-30 noon → Mon 2028-01-03.
        XCTAssertEqual(days(PickupDateCalculator.availableDates(from: date(2027,12,30), count: 1)), ["2028-01-03"])
    }
}
