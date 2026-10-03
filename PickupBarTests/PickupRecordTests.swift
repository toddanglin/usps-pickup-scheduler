import XCTest
@testable import PickupBar

final class PickupRecordTests: XCTestCase {

    private func chicago(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = PickupDateCalculator.timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour, minute: minute))!
    }

    private func record(_ date: String, packages: [PackageLine] = []) -> PickupRecord {
        PickupRecord(confirmationNumber: "WTC\(date)", pickupDate: date, createdAt: Date(),
                     packages: packages, estimatedWeight: 0, location: .frontDoor,
                     addressLine: "")
    }

    func testIsUpcomingTodayAndLater() {
        let now = chicago(2026, 10, 3, 9)
        XCTAssertTrue(record("2026-10-03").isUpcoming(asOf: now))
        XCTAssertTrue(record("2026-10-05").isUpcoming(asOf: now))
        XCTAssertFalse(record("2026-10-02").isUpcoming(asOf: now))
    }

    func testIsUpcomingUsesChicagoDayNotUTC() {
        // 23:30 in Chicago on Oct 3 is already Oct 4 in UTC; Oct 3 is still today.
        let lateEvening = chicago(2026, 10, 3, 23, 30)
        XCTAssertTrue(record("2026-10-03").isUpcoming(asOf: lateEvening))
        // Just after midnight Chicago on Oct 4, Oct 3 is past.
        let afterMidnight = chicago(2026, 10, 4, 0, 5)
        XCTAssertFalse(record("2026-10-03").isUpcoming(asOf: afterMidnight))
    }

    func testUnparseableDateCountsAsUpcoming() {
        XCTAssertTrue(record("soon").isUpcoming(asOf: Date()))
        XCTAssertEqual(record("soon").shortDisplayDate, "soon")
    }

    func testShortDisplayDateAndSummary() {
        let r = record("2026-10-03", packages: [PackageLine(packageType: .priorityMail, packageCount: 2),
                                                PackageLine(packageType: .groundAdvantage, packageCount: 1)])
        XCTAssertEqual(r.shortDisplayDate, "Sat, Oct 3")
        XCTAssertEqual(r.packageSummary, "2 Priority Mail, 1 Ground Advantage")
        XCTAssertEqual(r.totalPackages, 3)
        XCTAssertEqual(record("2026-10-03").packageSummary, "—")
    }

    func testCodableRoundTrip() throws {
        let r = PickupRecord(confirmationNumber: "WTC1", pickupDate: "2026-10-03",
                             createdAt: Date(timeIntervalSince1970: 1_000_000),
                             packages: [PackageLine(packageType: .returns, packageCount: 4)],
                             estimatedWeight: 2.5, location: .porch,
                             addressLine: "1 MAIN ST, SPRINGFIELD IL")
        let decoded = try JSONDecoder().decode(PickupRecord.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(decoded, r)
        XCTAssertEqual(decoded.id, "WTC1")
    }
}
