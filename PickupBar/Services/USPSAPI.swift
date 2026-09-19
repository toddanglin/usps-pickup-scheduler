import Foundation

/// An OAuth access token plus the moment it stops being usable, and what the
/// token is actually allowed to do.
struct OAuthToken: Codable, Equatable, Sendable {
    var accessToken: String
    var expiresAt: Date
    /// Scopes USPS granted, split out of the response's space-separated
    /// `scope`. Empty when the response did not say.
    var scopes: [String] = []
    /// The response's `api_products`, e.g. `"[Default Access]"`.
    var apiProducts: String?

    /// Whether this token can call the Carrier Pickup endpoints. An empty
    /// scope list says nothing either way, so it counts as allowed.
    var allowsPickup: Bool { scopes.isEmpty || scopes.contains("pickup") }

    init(accessToken: String, expiresAt: Date, scopes: [String] = [], apiProducts: String? = nil) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.apiProducts = apiProducts
    }

    // Decoded by hand so a payload written before `scopes` existed still reads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        scopes = try container.decodeIfPresent([String].self, forKey: .scopes) ?? []
        apiProducts = try container.decodeIfPresent(String.self, forKey: .apiProducts)
    }
}

/// The three USPS calls PickupBar makes. Implemented by `LiveUSPSClient` and
/// by fakes in tests.
protocol USPSAPI: Sendable {
    func fetchToken(clientID: String, clientSecret: String) async throws -> OAuthToken
    /// Returns the USPS-standardized form of `address`.
    func checkEligibility(_ address: PostalAddress, token: String) async throws -> PostalAddress
    func schedulePickup(_ request: SchedulePickupRequest, token: String) async throws -> PickupConfirmation
}
