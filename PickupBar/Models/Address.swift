import Foundation

// Wire shapes follow `components.schemas` in `docs/usps/carrier-pickup-v3.yaml`
// (USPS Carrier Pickup 3.1.10), which is the contract. USPS rejects unknown
// keys, and optional fields are omitted rather than sent as JSON `null`.

struct PostalAddress: Equatable, Sendable {
    var streetAddress: String
    var secondaryAddress: String?
    var city: String
    var state: String
    var ZIPCode: String
    var ZIPPlus4: String?
}

extension PostalAddress: Codable {
    private enum CodingKeys: String, CodingKey {
        case streetAddress, secondaryAddress, city, state, ZIPCode, ZIPPlus4
    }

    /// Optional fields are left out when nil or empty: `ZIPPlus4` must match
    /// `^\d{4}$` when present, so an empty string would be rejected.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(streetAddress, forKey: .streetAddress)
        try container.encodeIfPresent(secondaryAddress?.nonEmptyValue, forKey: .secondaryAddress)
        try container.encode(city, forKey: .city)
        try container.encode(state, forKey: .state)
        try container.encode(ZIPCode, forKey: .ZIPCode)
        try container.encodeIfPresent(ZIPPlus4?.nonEmptyValue, forKey: .ZIPPlus4)
    }
}

/// App-side contact model. Not a wire type — converted to `ContactEntry` values
/// when building a `PickupAddress` for USPS requests.
///
/// At least one of `email` and a 10-digit `phone` is expected; `phone` may be
/// empty. Settings written by v1.0 always have a phone and may lack an email.
struct PickupContact: Equatable, Sendable {
    var firstName: String
    var lastName: String
    var firm: String?
    /// Digits only, or empty when the user gave just an email.
    var phone: String
    var email: String?
}

extension PickupContact: Codable {
    private enum CodingKeys: String, CodingKey {
        case firstName, lastName, firm, phone, email
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        firstName = try container.decode(String.self, forKey: .firstName)
        lastName = try container.decode(String.self, forKey: .lastName)
        firm = try container.decodeIfPresent(String.self, forKey: .firm)
        phone = try container.decodeIfPresent(String.self, forKey: .phone) ?? ""
        email = try container.decodeIfPresent(String.self, forKey: .email)
    }
}

/// Wire representation of one `NotificationMethod` inside
/// `PickupAddress.contact`: the spec's `oneOf` `EmailNotification`
/// (`{"email": x}`) or `SMSNotification` (`{"cellNumber": "^\d{10}$"}`).
///
/// There is no `phone` key in the request schema — USPS rejects it. Decoding
/// is lenient because responses have used other spellings: `email`/`eMail` read
/// as `.email`, `cellNumber`/`phone` as `.cellNumber` (any `extension` is
/// ignored), and an empty or unrecognized object as `.email(nil)`.
enum ContactEntry: Equatable, Sendable {
    case email(String?)
    case cellNumber(String?)
}

extension ContactEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case email
        case eMail
        case cellNumber
        case phone
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.email) {
            self = .email(try? container.decodeIfPresent(String.self, forKey: .email))
        } else if container.contains(.eMail) {
            self = .email(try? container.decodeIfPresent(String.self, forKey: .eMail))
        } else if container.contains(.cellNumber) {
            self = .cellNumber(try? container.decodeIfPresent(String.self, forKey: .cellNumber))
        } else if container.contains(.phone) {
            self = .cellNumber(try? container.decodeIfPresent(String.self, forKey: .phone))
        } else {
            // USPS echoes `{}` for a contact method it did not keep.
            self = .email(nil)
        }
    }

    /// A nil or empty value is omitted, never encoded as `null`.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .email(let value):
            try container.encodeIfPresent(value?.nonEmptyValue, forKey: .email)
        case .cellNumber(let value):
            try container.encodeIfPresent(value?.nonEmptyValue, forKey: .cellNumber)
        }
    }
}

/// Wire shape for `PickupAddress`: `Addressee` (`firstName`, `lastName`,
/// `firm`) plus `address` and `contact` (1–2 entries).
struct PickupAddress: Equatable, Sendable {
    var firstName: String
    var lastName: String
    var firm: String?
    var address: PostalAddress
    var contact: [ContactEntry]
}

extension PickupAddress: Codable {
    private enum CodingKeys: String, CodingKey {
        case firstName, lastName, firm, address, contact
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(firstName, forKey: .firstName)
        try container.encode(lastName, forKey: .lastName)
        try container.encodeIfPresent(firm?.nonEmptyValue, forKey: .firm)
        try container.encode(address, forKey: .address)
        try container.encode(contact, forKey: .contact)
    }
}

extension PickupAddress {
    /// Builds a wire `PickupAddress` from the app-side `PickupContact`:
    /// `[.email]` when there is an email, plus `[.cellNumber]` when the phone
    /// is exactly 10 digits. Always yields 1–2 entries; if neither is usable
    /// (the address form prevents that) the phone digits are sent as-is so
    /// USPS reports the problem instead of the app sending an empty list.
    init(contact: PickupContact, address: PostalAddress) {
        self.firstName = contact.firstName
        self.lastName = contact.lastName
        self.firm = contact.firm?.nonEmptyValue
        self.address = address
        var entries: [ContactEntry] = []
        if let email = contact.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            entries.append(.email(email))
        }
        let digits = contact.phone.filter(\.isASCIIDigit)
        if digits.count == 10 || entries.isEmpty {
            entries.append(.cellNumber(digits))
        }
        self.contact = entries
    }
}

extension String {
    /// Nil when the string is empty, so optional wire fields are omitted.
    var nonEmptyValue: String? { isEmpty ? nil : self }
}

extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
