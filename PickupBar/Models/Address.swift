import Foundation

struct PostalAddress: Codable, Equatable, Sendable {
    var streetAddress: String
    var secondaryAddress: String?
    var city: String
    var state: String
    var ZIPCode: String
    var ZIPPlus4: String?
}

/// App-side contact model. Not a wire type — converted to `ContactEntry` values
/// when building a `PickupAddress` for USPS requests.
struct PickupContact: Codable, Equatable, Sendable {
    var firstName: String
    var lastName: String
    var firm: String?
    var phone: String
    var email: String?
}

/// Wire representation of a single contact method inside `PickupAddress.contact`.
/// Encodes as `{"email": x}` or `{"phone": x}`. Decodes contact entries keyed by
/// "email" or "eMail" (USPS eligibility responses use "eMail") or "phone"
/// (ignoring any "extension" field).
enum ContactEntry: Equatable, Sendable {
    case email(String?)
    case phone(String?)
}

extension ContactEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case email
        case eMail
        case phone
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.email) {
            self = .email(try container.decodeIfPresent(String.self, forKey: .email))
        } else if container.contains(.eMail) {
            self = .email(try container.decodeIfPresent(String.self, forKey: .eMail))
        } else if container.contains(.phone) {
            self = .phone(try container.decodeIfPresent(String.self, forKey: .phone))
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .email, in: container,
                debugDescription: "Expected one of email, eMail, phone")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .email(let value):
            try container.encode(value, forKey: .email)
        case .phone(let value):
            try container.encode(value, forKey: .phone)
        }
    }
}

/// Wire shape for a pickup address, matching the USPS Carrier Pickup 3.0 API.
struct PickupAddress: Codable, Equatable, Sendable {
    var firstName: String
    var lastName: String
    var firm: String?
    var address: PostalAddress
    var contact: [ContactEntry]
}

extension PickupAddress {
    /// Builds a wire `PickupAddress` from the app-side `PickupContact`, omitting
    /// the email contact entry when no email is provided.
    init(contact: PickupContact, address: PostalAddress) {
        self.firstName = contact.firstName
        self.lastName = contact.lastName
        self.firm = contact.firm
        self.address = address
        var entries: [ContactEntry] = []
        if let email = contact.email, !email.isEmpty {
            entries.append(.email(email))
        }
        entries.append(.phone(contact.phone))
        self.contact = entries
    }
}
