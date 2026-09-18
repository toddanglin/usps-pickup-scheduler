// TEMPORARY — deleted on merge; real definitions live in Models/.
enum PackageLocation: String, CaseIterable, Codable, Sendable {
  case frontDoor = "FRONT_DOOR", backDoor = "BACK_DOOR", sideDoor = "SIDE_DOOR",
       knockOnDoor = "KNOCK_ON_DOOR", mailRoom = "MAIL_ROOM", office = "OFFICE",
       reception = "RECEPTION", mailbox = "IN_AT_MAILBOX", securityDeck = "SECURITY_DECK",
       shippingDock = "SHIPPING_DOCK", other = "OTHER"
}
struct PostalAddress: Codable, Equatable, Sendable {
  var streetAddress: String; var secondaryAddress: String?; var city: String; var state: String; var ZIPCode: String; var ZIPPlus4: String?
}
struct PickupContact: Codable, Equatable, Sendable {
  var firstName: String; var lastName: String; var firm: String?; var phone: String; var email: String?
}
struct PickupConfirmation: Codable, Equatable, Sendable { var confirmationNumber: String; var pickupDate: String }
