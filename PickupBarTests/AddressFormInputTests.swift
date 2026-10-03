import XCTest
@testable import PickupBar

/// Field rules for the address form, taken from the USPS Carrier Pickup
/// OpenAPI spec (`docs/usps/carrier-pickup-v3.yaml`).
final class AddressFormInputTests: XCTestCase {
    private func valid() -> AddressFormInput {
        AddressFormInput(firstName: "Todd", lastName: "Anglin", firm: "", email: "todd@example.com",
                         phone: "", street: "1 Main St", secondary: "", city: "Austin",
                         state: "TX", zip: "78701")
    }

    func testValidInputHasNoProblems() {
        XCTAssertEqual(valid().problems(), [])
    }

    func testPhoneOnlyIsEnough() {
        var input = valid()
        input.email = ""
        input.phone = "(512) 555-1234"
        XCTAssertEqual(input.problems(), [])
    }

    func testNeedsAnEmailOrAPhone() {
        var input = valid()
        input.email = "  "
        input.phone = ""
        XCTAssertEqual(input.problems(), ["Enter an email (recommended) or a 10-digit cell phone."])
    }

    func testPartialPhoneIsAProblemEvenWithAnEmail() {
        var input = valid()
        input.phone = "512555"
        XCTAssertEqual(input.problems(), ["Phone must be 10 digits."])
    }

    func testEmailShape() {
        var input = valid()
        for bad in ["todd", "todd@example", "@example.com", "todd@@example.com", "to dd@example.com"] {
            input.email = bad
            XCTAssertEqual(input.problems(), ["Enter a valid email address."], bad)
        }
        input.email = String(repeating: "a", count: 39) + "@example.com" // 51
        XCTAssertEqual(input.problems(), ["Email must be 50 characters or fewer."])
    }

    func testLengthLimits() {
        var input = valid()
        let long51 = String(repeating: "x", count: 51)
        input.firstName = long51
        input.lastName = long51
        input.firm = long51
        input.street = long51
        input.secondary = long51
        input.city = String(repeating: "c", count: 29)
        XCTAssertEqual(input.problems(), [
            "First name must be 50 characters or fewer.",
            "Last name must be 50 characters or fewer.",
            "Company must be 50 characters or fewer.",
            "Street must be 50 characters or fewer.",
            "Apt/Suite must be 50 characters or fewer.",
            "City must be 28 characters or fewer.",
        ])
    }

    func testLimitsAreInclusive() {
        var input = valid()
        let fifty = String(repeating: "x", count: 50)
        input.firstName = fifty
        input.lastName = fifty
        input.firm = fifty
        input.street = fifty
        input.secondary = fifty
        input.city = String(repeating: "c", count: 28)
        XCTAssertEqual(input.problems(), [])
    }

    func testRequiredFields() {
        let input = AddressFormInput(firstName: "", lastName: " ", firm: "", email: "a@b.co", phone: "",
                                     street: "", secondary: "", city: "", state: "T", zip: "123")
        XCTAssertEqual(input.problems(), [
            "First name is required.",
            "Last name is required.",
            "Street is required.",
            "City is required.",
            "State must be 2 letters.",
            "ZIP must be 5 digits.",
        ])
    }
}
