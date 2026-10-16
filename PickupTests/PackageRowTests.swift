import XCTest
@testable import Pickup

final class PackageRowTests: XCTestCase {
    func testParseClampsAndTreatsEmptyAsZero() {
        XCTAssertEqual(PackageRow.parse(""), 0)
        XCTAssertEqual(PackageRow.parse("7"), 7)
        XCTAssertEqual(PackageRow.parse("007"), 7)
        XCTAssertEqual(PackageRow.parse("3a"), 3)
        XCTAssertEqual(PackageRow.parse("51"), 50)
        XCTAssertEqual(PackageRow.parse("999999999999999999999"), 50)
    }

    func testDisplayLeavesZeroToThePlaceholder() {
        XCTAssertEqual(PackageRow.display(0), "")
        XCTAssertEqual(PackageRow.display(12), "12")
    }
}
