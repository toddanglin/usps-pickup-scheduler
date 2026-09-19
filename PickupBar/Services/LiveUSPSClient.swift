import Foundation

/// Talks to the USPS Carrier Pickup 3.0 REST API over `URLSession`.
///
/// Every public method funnels through `send(_:)`, which performs the request
/// and turns transport failures into `USPSError`, and `mapStatus(_:data:)`,
/// which turns non-2xx responses into `USPSError`.
final class LiveUSPSClient: USPSAPI {
    private let baseURL: URL
    private let session: URLSession

    private static let timeout: TimeInterval = 30
    private static let maxBodyCharacters = 2000

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// `JSONEncoder` is a reference type, so each call gets its own rather than
    /// sharing one across concurrent callers of this `Sendable` client.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    // MARK: - Token

    func fetchToken(clientID: String, clientSecret: String) async throws -> OAuthToken {
        var request = makeRequest(path: "/oauth2/v3/token")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try Self.makeEncoder().encode(TokenRequestBody(grantType: "client_credentials",
                                                                          clientID: clientID,
                                                                          clientSecret: clientSecret))

        let requestedAt = Date()
        let (status, data) = try await send(request)
        guard (200..<300).contains(status) else {
            // The token endpoint reports bad credentials as 401, or as a 400
            // carrying `{"error":"invalid_client"}`. Any other 400 is a
            // malformed request, not a credential problem.
            if status == 401 { throw USPSError.invalidCredentials }
            if status == 400, Self.isCredentialRejection(data) { throw USPSError.invalidCredentials }
            throw mapStatus(status, data: data)
        }

        do {
            let body = try JSONDecoder().decode(TokenResponseBody.self, from: data)
            return OAuthToken(accessToken: body.accessToken,
                              expiresAt: requestedAt.addingTimeInterval(body.expiresIn),
                              scopes: body.scopes,
                              apiProducts: body.apiProducts)
        } catch {
            throw USPSError.decoding(String(describing: error))
        }
    }

    // MARK: - Eligibility

    func checkEligibility(_ address: PostalAddress, token: String) async throws -> PostalAddress {
        var components = URLComponents(url: baseURL.appendingPathComponent("/pickup/v3/carrier-pickup/eligibility"),
                                       resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "streetAddress", value: address.streetAddress)]
        if let secondary = address.secondaryAddress, !secondary.isEmpty {
            items.append(URLQueryItem(name: "secondaryAddress", value: secondary))
        }
        items.append(URLQueryItem(name: "city", value: address.city))
        items.append(URLQueryItem(name: "state", value: address.state))
        items.append(URLQueryItem(name: "ZIPCode", value: address.ZIPCode))
        if let plus4 = address.ZIPPlus4, !plus4.isEmpty {
            items.append(URLQueryItem(name: "ZIPPlus4", value: plus4))
        }
        components.queryItems = items
        // `URLComponents` leaves `+` literal in a query, where USPS (like most
        // servers) reads it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")

        var request = URLRequest(url: components.url!, timeoutInterval: Self.timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (status, data) = try await send(request)
        guard (200..<300).contains(status) else {
            // A 400 here means USPS could not match the address, which is a
            // user-fixable problem rather than a malformed request.
            if status == 400 {
                let body = try? JSONDecoder().decode(USPSErrorBody.self, from: data)
                let message = body?.error?.message?.nonEmpty ?? "Address not eligible for carrier pickup."
                throw USPSError.addressNotEligible(message: message)
            }
            throw mapStatus(status, data: data)
        }

        do {
            return try JSONDecoder().decode(EligibilityResponse.self, from: data).address
        } catch {
            throw USPSError.decoding(String(describing: error))
        }
    }

    // MARK: - Schedule

    func schedulePickup(_ pickup: SchedulePickupRequest, token: String) async throws -> PickupConfirmation {
        var request = makeRequest(path: "/pickup/v3/carrier-pickup")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try Self.makeEncoder().encode(pickup)

        let (status, data) = try await send(request)
        guard (200..<300).contains(status) else { throw mapStatus(status, data: data) }

        do {
            return try JSONDecoder().decode(ConfirmationResponse.self, from: data).confirmation
        } catch {
            throw USPSError.decoding(String(describing: error))
        }
    }

    // MARK: - Plumbing

    private func makeRequest(path: String) -> URLRequest {
        URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: Self.timeout)
    }

    /// Performs `request`, returning the status code and body, and translating
    /// `URLError`s into `USPSError`.
    private func send(_ request: URLRequest) async throws -> (Int, Data) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw USPSError.unexpected(status: 0, body: "Response was not an HTTP response.")
            }
            return (http.statusCode, data)
        } catch let error as USPSError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .timedOut:
                throw USPSError.offline
            default:
                throw USPSError.unexpected(status: 0, body: error.localizedDescription)
            }
        } catch {
            throw USPSError.unexpected(status: 0, body: error.localizedDescription)
        }
    }

    /// Maps a non-2xx status plus its body onto a `USPSError`.
    private func mapStatus(_ status: Int, data: Data) -> USPSError {
        switch status {
        case 401:
            // A 401 on a resource call is usually a dead token, but USPS also
            // uses it when the app's products do not cover the endpoint — the
            // credentials are fine and re-entering them would not help.
            return Self.isScopeRejection(data) ? .insufficientScope(granted: []) : .invalidCredentials
        case 403:
            return .forbidden
        case 429:
            return .rateLimited
        case 502, 503, 504:
            return .serviceUnavailable
        case 400:
            let body = try? JSONDecoder().decode(USPSErrorBody.self, from: data)
            let message = body?.error?.message?.nonEmpty ?? "USPS rejected the request."
            let details = (body?.error?.errors ?? []).compactMap { detail -> String? in
                detail.message?.nonEmpty ?? detail.detail?.nonEmpty ?? detail.title?.nonEmpty
            }
            return .badRequest(message: message, details: details)
        default:
            return .unexpected(status: status, body: Self.trimmedBody(data))
        }
    }

    /// True when a 401 body blames the token's OAuth scope rather than the
    /// token itself.
    private static func isScopeRejection(_ data: Data) -> Bool {
        guard let body = try? JSONDecoder().decode(USPSErrorBody.self, from: data),
              let error = body.error else { return false }
        if (error.errors ?? []).contains(where: { $0.title?.lowercased() == "invalid_oauth_scope" }) {
            return true
        }
        return error.message?.lowercased().contains("scope") ?? false
    }

    /// True when a 400 from the token endpoint carries an OAuth error code
    /// that means the credentials themselves were rejected.
    private static func isCredentialRejection(_ data: Data) -> Bool {
        guard let body = try? JSONDecoder().decode(TokenErrorBody.self, from: data),
              let code = body.error else { return false }
        return ["invalid_client", "invalid_grant", "unauthorized_client"].contains(code)
    }

    private static func trimmedBody(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        guard text.count > maxBodyCharacters else { return text }
        return String(text.prefix(maxBodyCharacters))
    }
}

// MARK: - Wire types

private struct TokenRequestBody: Encodable {
    var grantType: String
    var clientID: String
    var clientSecret: String

    enum CodingKeys: String, CodingKey {
        case grantType = "grant_type"
        case clientID = "client_id"
        case clientSecret = "client_secret"
    }
}

/// The token endpoint reports failures as `{"error": "invalid_client", ...}`,
/// where `error` is a string rather than the object the pickup endpoints use.
private struct TokenErrorBody: Decodable {
    var error: String?
}

/// USPS documents `expires_in` and `issued_at` as numbers, but some responses
/// deliver them as numeric strings, so both are accepted.
private struct TokenResponseBody: Decodable {
    var accessToken: String
    var expiresIn: TimeInterval
    /// `scope` split on spaces — USPS lists every product the app can reach.
    var scopes: [String] = []
    var apiProducts: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case scope
        case apiProducts = "api_products"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        scopes = (try container.decodeIfPresent(String.self, forKey: .scope) ?? "")
            .split(separator: " ").map(String.init)
        apiProducts = try container.decodeIfPresent(String.self, forKey: .apiProducts)
        if let number = try? container.decode(Double.self, forKey: .expiresIn) {
            expiresIn = number
        } else {
            let text = try container.decode(String.self, forKey: .expiresIn)
            guard let parsed = Double(text) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .expiresIn, in: container,
                    debugDescription: "expires_in was neither a number nor a numeric string")
            }
            expiresIn = parsed
        }
    }
}

/// The eligibility endpoint returns either `{"pickupAddress": {...}}` or the
/// same object at the top level.
private struct EligibilityResponse: Decodable {
    var address: PostalAddress

    private struct Envelope: Decodable {
        var address: PostalAddress
    }

    private enum CodingKeys: String, CodingKey {
        case pickupAddress
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           let nested = try? container.decode(Envelope.self, forKey: .pickupAddress) {
            address = nested.address
            return
        }
        address = try Envelope(from: decoder).address
    }
}

/// Schedule responses come back flat or nested under `carrierPickupRequest`.
///
/// The top level wins: when `nextAvailablePickup` rolls the date forward, the
/// nested `carrierPickupRequest` echoes the date that was *requested* while the
/// top level carries the date USPS actually *scheduled*. The nested object is
/// only consulted for keys the top level does not have.
private struct ConfirmationResponse: Decodable {
    var confirmation: PickupConfirmation

    private enum CodingKeys: String, CodingKey {
        case confirmationNumber
        case pickupDate
        case carrierPickupRequest
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nested = try? container.decode(PickupConfirmation.self, forKey: .carrierPickupRequest)
        let number = (try? container.decode(String.self, forKey: .confirmationNumber))
            ?? nested?.confirmationNumber
        let date = (try? container.decode(String.self, forKey: .pickupDate)) ?? nested?.pickupDate

        guard let number, let date else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: container.codingPath,
                                      debugDescription: "No confirmationNumber/pickupDate at the top level or under carrierPickupRequest."))
        }
        confirmation = PickupConfirmation(confirmationNumber: number, pickupDate: date)
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
