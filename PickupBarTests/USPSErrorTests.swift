import XCTest
@testable import PickupBar

final class USPSErrorTests: XCTestCase {
    func testOfflineCopy() {
        let error = USPSError.offline
        XCTAssertEqual(error.title, "You're offline")
        XCTAssertEqual(error.message, "PickupBar couldn't reach USPS.")
        XCTAssertEqual(error.hint, "Check your connection and try again.")
    }

    func testInvalidCredentialsCopy() {
        let error = USPSError.invalidCredentials
        XCTAssertEqual(error.title, "USPS rejected your API credentials")
        XCTAssertEqual(error.message, "The Consumer Key or Secret is wrong, expired, or was revoked.")
        XCTAssertEqual(error.hint, "Open Settings › Account to update them.")
    }

    func testBadRequestUsesMessageAndJoinedDetails() {
        let error = USPSError.badRequest(message: "Pickup date is invalid.",
                                         details: ["pickupDate must be a weekday", "weight too high"])
        XCTAssertEqual(error.title, "USPS couldn't schedule this pickup")
        XCTAssertEqual(error.message, "Pickup date is invalid.")
        XCTAssertEqual(error.hint, "pickupDate must be a weekday\nweight too high")
    }

    func testBadRequestWithNoDetailsHasNoHint() {
        XCTAssertNil(USPSError.badRequest(message: "nope", details: []).hint)
    }

    func testUnexpectedWithZeroStatusUsesBodyAsMessage() {
        XCTAssertEqual(USPSError.unexpected(status: 0, body: "The request timed out.").message,
                       "The request timed out.")
        XCTAssertEqual(USPSError.unexpected(status: 418, body: "teapot").message,
                       "USPS returned status 418.")
    }

    func testDecodingCopy() {
        let error = USPSError.decoding("keyNotFound")
        XCTAssertEqual(error.title, "Something unexpected happened")
        XCTAssertEqual(error.message, "PickupBar couldn't read the USPS response.")
        XCTAssertEqual(error.hint,
                       "The pickup may still have been scheduled. Check usps.com before scheduling again.")
        XCTAssertFalse(error.isRetryable)
    }

    func testIsRetryableForAllCases() {
        XCTAssertTrue(USPSError.offline.isRetryable)
        XCTAssertTrue(USPSError.rateLimited.isRetryable)
        XCTAssertTrue(USPSError.serviceUnavailable.isRetryable)
        XCTAssertTrue(USPSError.unexpected(status: 500, body: "boom").isRetryable)

        XCTAssertFalse(USPSError.invalidCredentials.isRetryable)
        XCTAssertFalse(USPSError.forbidden.isRetryable)
        XCTAssertFalse(USPSError.badRequest(message: "m", details: []).isRetryable)
        XCTAssertFalse(USPSError.addressNotEligible(message: "m").isRetryable)
        // A decode failure follows a 2xx, so retrying could double-schedule.
        XCTAssertFalse(USPSError.decoding("bad").isRetryable)
    }

    func testTechnicalDetailsIncludeStatusAndBody() {
        let details = USPSError.unexpected(status: 503, body: "<html>down</html>").technicalDetails
        XCTAssertTrue(details.contains("PickupBar"))
        XCTAssertTrue(details.contains("unexpected"))
        XCTAssertTrue(details.contains("503"))
        XCTAssertTrue(details.contains("<html>down</html>"))
    }

    func testTechnicalDetailsForSimpleCase() {
        let details = USPSError.forbidden.technicalDetails
        XCTAssertTrue(details.contains("forbidden"))
        XCTAssertFalse(details.isEmpty)
    }
}
