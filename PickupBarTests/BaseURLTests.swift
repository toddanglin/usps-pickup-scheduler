import XCTest
@testable import PickupBar

final class BaseURLTests: XCTestCase {
    func testDefaultsToProduction() {
        XCTAssertEqual(BaseURL.resolve(useTestEnvironment: false, environment: [:]),
                       URL(string: "https://apis.usps.com")!)
    }

    func testTestToggleSelectsTEM() {
        XCTAssertEqual(BaseURL.resolve(useTestEnvironment: true, environment: [:]),
                       URL(string: "https://apis-tem.usps.com")!)
    }

    func testEnvironmentVariableOverridesEverything() {
        let env = ["PICKUPBAR_BASE_URL": "http://127.0.0.1:8787"]
        XCTAssertEqual(BaseURL.resolve(useTestEnvironment: true, environment: env),
                       URL(string: "http://127.0.0.1:8787")!)
        XCTAssertEqual(BaseURL.resolve(useTestEnvironment: false, environment: env),
                       URL(string: "http://127.0.0.1:8787")!)
    }

    func testBlankOrInvalidEnvironmentVariableIsIgnored() {
        XCTAssertEqual(BaseURL.resolve(useTestEnvironment: false, environment: ["PICKUPBAR_BASE_URL": "   "]),
                       BaseURL.production)
    }

    func testEnvironmentVariableWithoutSchemeIsIgnored() {
        // "localhost:8787" parses as a URL whose scheme is "localhost".
        XCTAssertEqual(BaseURL.resolve(useTestEnvironment: false,
                                       environment: ["PICKUPBAR_BASE_URL": "localhost:8787"]),
                       BaseURL.production)
        XCTAssertEqual(BaseURL.resolve(useTestEnvironment: true,
                                       environment: ["PICKUPBAR_BASE_URL": "localhost:8787"]),
                       BaseURL.test)
    }

    func testEnvironmentVariableWithNonHTTPSchemeIsIgnored() {
        XCTAssertEqual(BaseURL.resolve(useTestEnvironment: false,
                                       environment: ["PICKUPBAR_BASE_URL": "file:///tmp/usps"]),
                       BaseURL.production)
    }

    func testEnvironmentVariableWithHTTPSchemeAndHostIsAccepted() {
        XCTAssertEqual(BaseURL.resolve(useTestEnvironment: false,
                                       environment: ["PICKUPBAR_BASE_URL": "http://127.0.0.1:8787"]),
                       URL(string: "http://127.0.0.1:8787")!)
    }
}
