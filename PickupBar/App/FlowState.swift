import Foundation

/// Which screen the menu bar popover is showing.
enum FlowState: Equatable {
    case needsCredentials
    case needsAddress
    case form
    /// A new pickup is being scheduled.
    case scheduling
    /// Some other USPS call is in flight (loading, updating or cancelling a
    /// pickup); the label says which, e.g. "Cancelling your pickup…".
    case working(String)
    /// The pickup form, editing the existing pickup with this number.
    case modifying(confirmationNumber: String)
    case confirmed(PickupConfirmation)
    case failed(USPSError, retryable: Bool)
    /// "Scheduled pickups", the local history.
    case history
}

/// Whether the confirmation screen is for a new pickup or a changed one.
enum ConfirmationMode: Equatable {
    case scheduled
    case updated
}

/// The pickup being modified and the ETag USPS gave for it.
struct PendingEdit: Equatable {
    var confirmationNumber: String
    var etag: String
}

/// What the app currently believes about the stored USPS credentials.
enum CredentialsStatus: Equatable {
    case unknown
    case missing
    case checking
    case valid
    case invalid
}
