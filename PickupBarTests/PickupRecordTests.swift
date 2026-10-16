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

    // MARK: - Status

    func testNewRecordsAreScheduled() {
        XCTAssertEqual(record("2026-10-03").status, .scheduled)
        XCTAssertNil(record("2026-10-03").updatedAt)
    }

    func testCancelledIsNeverUpcoming() {
        let now = chicago(2026, 10, 3, 9)
        var r = record("2026-10-05")
        r.status = .cancelled
        XCTAssertFalse(r.isUpcoming(asOf: now))
    }

    func testStatusAndUpdatedAtRoundTrip() throws {
        var r = record("2026-10-05")
        r.status = .cancelled
        r.updatedAt = Date(timeIntervalSince1970: 2_000_000)
        let decoded = try JSONDecoder().decode(PickupRecord.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(decoded, r)
    }

    func testRecordWithoutStatusDecodesAsScheduled() throws {
        let json = #"{"confirmationNumber":"WTC1","pickupDate":"2026-10-03","createdAt":0,"packages":[],"totalPackages":0,"estimatedWeight":0,"location":"PORCH","addressLine":""}"#
        let decoded = try JSONDecoder().decode(PickupRecord.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.status, .scheduled)
        XCTAssertNil(decoded.updatedAt)
        XCTAssertEqual(decoded.location, .porch)
    }

    func testUnknownStatusDecodesAsScheduled() throws {
        let json = #"{"confirmationNumber":"WTC1","pickupDate":"2026-10-03","createdAt":0,"packages":[],"totalPackages":0,"estimatedWeight":0,"location":"PORCH","addressLine":"","status":"rescheduled"}"#
        let decoded = try JSONDecoder().decode(PickupRecord.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.status, .scheduled)
    }
}
