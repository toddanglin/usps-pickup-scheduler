import Foundation

/// The raw text of the address form, and the rules it must pass before
/// the app asks USPS to verify it. Length limits come from the USPS Carrier
/// Pickup spec (`docs/usps/carrier-pickup-v3.yaml`): names, firm, street and
/// apt ≤ 50, city ≤ 28, email ≤ 50. Fields are validated on save, never
/// truncated while the user types.
struct AddressFormInput: Equatable {
    var firstName: String
    var lastName: String
    var firm: String
    var email: String
    var phone: String
    var street: String
    var secondary: String
    var city: String
    var state: String
    var zip: String

    static let nameLimit = 50
    static let firmLimit = 50
    static let streetLimit = 50
    static let secondaryLimit = 50
    static let cityLimit = 28
    static let emailLimit = 50

    /// Human-readable list of everything still wrong with the form, in field
    /// order. Empty when the form can be saved.
    func problems() -> [String] {
        var problems: [String] = []
        func limit(_ value: String, _ max: Int, _ label: String) {
            if value.trimmedValue.count > max { problems.append("\(label) must be \(max) characters or fewer.") }
        }

        if firstName.trimmedValue.isEmpty { problems.append("First name is required.") }
        limit(firstName, Self.nameLimit, "First name")
        if lastName.trimmedValue.isEmpty { problems.append("Last name is required.") }
        limit(lastName, Self.nameLimit, "Last name")
        limit(firm, Self.firmLimit, "Company")

        let email = email.trimmedValue
        if email.count > Self.emailLimit {
            problems.append("Email must be \(Self.emailLimit) characters or fewer.")
        } else if !email.isEmpty, !Self.isPlausibleEmail(email) {
            problems.append("Enter a valid email address.")
        }
        let phoneDigits = phone.filter(\.isNumber)
        if !phoneDigits.isEmpty, phoneDigits.count != 10 {
            problems.append("Phone must be 10 digits.")
        }
        if email.isEmpty, phoneDigits.isEmpty {
            problems.append("Enter an email (recommended) or a 10-digit cell phone.")
        }

        if street.trimmedValue.isEmpty { problems.append("Street is required.") }
        limit(street, Self.streetLimit, "Street")
        limit(secondary, Self.secondaryLimit, "Apt/Suite")
        if city.trimmedValue.isEmpty { problems.append("City is required.") }
        limit(city, Self.cityLimit, "City")
        if state.count != 2 || !state.allSatisfy(\.isLetter) {
            problems.append("State must be 2 letters.")
        }
        if zip.filter(\.isNumber).count != 5 { problems.append("ZIP must be 5 digits.") }
        return problems
    }

    /// A basic `x@y.z` shape check — USPS validates the address itself.
    static func isPlausibleEmail(_ value: String) -> Bool {
        value.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
    }
}

private extension String {
    var trimmedValue: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
