import Foundation

/// Where the carrier finds the packages. Raw values are the
/// `pickupLocation.packageLocation` enum in `docs/usps/carrier-pickup-v3.yaml`.
enum PackageLocation: String, CaseIterable, Sendable {
    case frontDoor = "FRONT_DOOR"
    case backDoor = "BACK_DOOR"
    case sideDoor = "SIDE_DOOR"
    case knockOnDoor = "KNOCK_ON_DOOR"
    case mailRoom = "MAIL_ROOM"
    case office = "OFFICE"
    case porch = "PORCH"
    case reception = "RECEPTION"
    case mailbox = "MAILBOX"
    case other = "OTHER"

    var displayName: String {
        switch self {
        case .frontDoor: return "Front Door"
        case .backDoor: return "Back Door"
        case .sideDoor: return "Side Door"
        case .knockOnDoor: return "Knock on Door / Ring Bell"
        case .mailRoom: return "Mail Room"
        case .office: return "Office"
        case .porch: return "Porch"
        case .reception: return "Reception"
        case .mailbox: return "Mailbox"
        case .other: return "Other"
        }
    }

    /// Maps a raw value, including one older versions of the app persisted
    /// (`IN_AT_MAILBOX`), onto a case. Returns nil for anything unrecognized,
    /// such as the retired `SECURITY_DECK` and `SHIPPING_DOCK`.
    init?(lenientRawValue raw: String) {
        if let known = PackageLocation(rawValue: raw) {
            self = known
        } else if raw == "IN_AT_MAILBOX" {
            self = .mailbox
        } else {
            return nil
        }
    }
}

extension PackageLocation: Codable {
    /// Unknown values decode as `.other` rather than failing.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PackageLocation(lenientRawValue: raw) ?? .other
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
