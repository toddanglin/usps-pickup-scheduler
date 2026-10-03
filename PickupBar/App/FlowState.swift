import Foundation

/// Which screen the menu bar popover is showing.
enum FlowState: Equatable {
    case needsCredentials
    case needsAddress
    case form
    case scheduling
    case confirmed(PickupConfirmation)
    case failed(USPSError, retryable: Bool)
    /// "Scheduled pickups", the local history.
    case history
}

/// What the app currently believes about the stored USPS credentials.
enum CredentialsStatus: Equatable {
    case unknown
    case missing
    case checking
    case valid
    case invalid
}
