import Foundation

/// An OAuth access token plus the moment it stops being usable.
struct OAuthToken: Codable, Equatable, Sendable {
    var accessToken: String
    var expiresAt: Date
}

/// The three USPS calls PickupBar makes. Implemented by `LiveUSPSClient` and
/// by fakes in tests.
protocol USPSAPI: Sendable {
    func fetchToken(clientID: String, clientSecret: String) async throws -> OAuthToken
    /// Returns the USPS-standardized form of `address`.
    func checkEligibility(_ address: PostalAddress, token: String) async throws -> PostalAddress
    func schedulePickup(_ request: SchedulePickupRequest, token: String) async throws -> PickupConfirmation
}
