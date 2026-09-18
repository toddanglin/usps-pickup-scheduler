import Foundation

enum PackageLocation: String, CaseIterable, Codable, Sendable {
    case frontDoor = "FRONT_DOOR"
    case backDoor = "BACK_DOOR"
    case sideDoor = "SIDE_DOOR"
    case knockOnDoor = "KNOCK_ON_DOOR"
    case mailRoom = "MAIL_ROOM"
    case office = "OFFICE"
    case reception = "RECEPTION"
    case mailbox = "IN_AT_MAILBOX"
    case securityDeck = "SECURITY_DECK"
    case shippingDock = "SHIPPING_DOCK"
    case other = "OTHER"

    var displayName: String {
        switch self {
        case .frontDoor: return "Front Door"
        case .backDoor: return "Back Door"
        case .sideDoor: return "Side Door"
        case .knockOnDoor: return "Knock on Door / Ring Bell"
        case .mailRoom: return "Mail Room"
        case .office: return "Office"
        case .reception: return "Reception"
        case .mailbox: return "In/At Mailbox"
        case .securityDeck: return "Security Deck"
        case .shippingDock: return "Shipping Dock"
        case .other: return "Other"
        }
    }
}
