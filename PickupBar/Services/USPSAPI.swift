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
    var allowsPickup: Bool { Self.scopesAllowPickup(scopes) }

    /// The one place that decides whether a scope list covers Carrier Pickup.
    /// USPS grants `carrier-pickup`; `pickup` is accepted too, since older
    /// documentation named the scope that way.
    static func scopesAllowPickup(_ scopes: [String]) -> Bool {
        scopes.isEmpty || scopes.contains("carrier-pickup") || scopes.contains("pickup")
    }

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

/// A pickup as `GET /carrier-pickup/{confirmationNumber}` (or a `PUT`) returns
/// it, plus the entity tag a following `PUT` or `DELETE` must send back.
struct FetchedPickup: Equatable, Sendable {
    var confirmation: PickupConfirmation
    /// The pickup's details, from `carrierPickupRequest`. Nil when USPS sent
    /// something PickupBar could not read; the confirmation is still usable.
    /// `nextAvailablePickup` is always false, and contact entries USPS
    /// echoes as `{}` or junk are already stripped.
    var request: SchedulePickupRequest?
    /// Good for one hour, or until it is used by a `PUT` or `DELETE`.
    var etag: String
}

/// The USPS calls PickupBar makes. Implemented by `LiveUSPSClient` and by
/// fakes in tests.
protocol USPSAPI: Sendable {
    func fetchToken(clientID: String, clientSecret: String) async throws -> OAuthToken
    /// Returns the USPS-standardized form of `address`.
    func checkEligibility(_ address: PostalAddress, token: String) async throws -> PostalAddress
    func schedulePickup(_ request: SchedulePickupRequest, token: String) async throws -> PickupConfirmation
    /// `GET /carrier-pickup/{confirmationNumber}`. USPS has no status field:
    /// a cancelled pickup reads back exactly like a scheduled one.
    func fetchPickup(confirmationNumber: String, token: String) async throws -> FetchedPickup
    /// `PUT /carrier-pickup/{confirmationNumber}` with `If-Match: etag`.
    /// `request.nextAvailablePickup` is never sent.
    func updatePickup(confirmationNumber: String, etag: String, request: SchedulePickupRequest,
                      token: String) async throws -> FetchedPickup
    /// `DELETE /carrier-pickup/{confirmationNumber}` with `If-Match: etag`.
    func cancelPickup(confirmationNumber: String, etag: String, token: String) async throws
}
