import Foundation
@testable import PickupBar

/// In-memory `USPSAPI` for tests. All results default to success; set the
/// `*Result` properties to drive failures. Thread-safe via an `NSLock`, so it
/// can be handed to an actor or used from concurrent tasks.
final class FakeUSPSAPI: USPSAPI, @unchecked Sendable {
    private let lock = NSLock()

    private var _tokenResult: Result<OAuthToken, Error> =
        .success(OAuthToken(accessToken: "fake-token", expiresAt: Date().addingTimeInterval(28_799)))
    private var _eligibilityResult: Result<PostalAddress, Error> = .success(FakeUSPSAPI.defaultAddress)
    private var _scheduleResult: Result<PickupConfirmation, Error> =
        .success(PickupConfirmation(confirmationNumber: "ABC123", pickupDate: "2026-09-21"))

    private var _tokenCallCount = 0
    private var _eligibilityCallCount = 0
    private var _scheduleCallCount = 0
    private var _lastScheduleRequest: SchedulePickupRequest?
    private var _lastEligibilityAddress: PostalAddress?
    private var _lastToken: String?
    private var _lastCredentials: (id: String, secret: String)?
    private var _tokenDelay: TimeInterval = 0

    static let defaultAddress = PostalAddress(
        streetAddress: "4120 BINGHAM AVE", secondaryAddress: nil, city: "SAINT LOUIS",
        state: "MO", ZIPCode: "63116", ZIPPlus4: "2520")

    // MARK: - Configuration

    var tokenResult: Result<OAuthToken, Error> {
        get { lock.withLock { _tokenResult } }
        set { lock.withLock { _tokenResult = newValue } }
    }

    var eligibilityResult: Result<PostalAddress, Error> {
        get { lock.withLock { _eligibilityResult } }
        set { lock.withLock { _eligibilityResult = newValue } }
    }

    var scheduleResult: Result<PickupConfirmation, Error> {
        get { lock.withLock { _scheduleResult } }
        set { lock.withLock { _scheduleResult = newValue } }
    }

    /// Artificial delay applied to `fetchToken`, useful for coalescing tests.
    var tokenDelay: TimeInterval {
        get { lock.withLock { _tokenDelay } }
        set { lock.withLock { _tokenDelay = newValue } }
    }

    // MARK: - Observations

    var tokenCallCount: Int { lock.withLock { _tokenCallCount } }
    var eligibilityCallCount: Int { lock.withLock { _eligibilityCallCount } }
    var scheduleCallCount: Int { lock.withLock { _scheduleCallCount } }
    var lastScheduleRequest: SchedulePickupRequest? { lock.withLock { _lastScheduleRequest } }
    var lastEligibilityAddress: PostalAddress? { lock.withLock { _lastEligibilityAddress } }
    var lastToken: String? { lock.withLock { _lastToken } }
    var lastCredentials: (id: String, secret: String)? { lock.withLock { _lastCredentials } }

    /// Convenience: a token that expires `seconds` from `now`.
    func setToken(_ accessToken: String = "fake-token", expiresIn seconds: TimeInterval,
                  from now: Date = Date()) {
        tokenResult = .success(OAuthToken(accessToken: accessToken,
                                          expiresAt: now.addingTimeInterval(seconds)))
    }

    // MARK: - USPSAPI

    func fetchToken(clientID: String, clientSecret: String) async throws -> OAuthToken {
        let (result, delay) = lock.withLock { () -> (Result<OAuthToken, Error>, TimeInterval) in
            _tokenCallCount += 1
            _lastCredentials = (id: clientID, secret: clientSecret)
            return (_tokenResult, _tokenDelay)
        }
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return try result.get()
    }

    func checkEligibility(_ address: PostalAddress, token: String) async throws -> PostalAddress {
        let result = lock.withLock { () -> Result<PostalAddress, Error> in
            _eligibilityCallCount += 1
            _lastEligibilityAddress = address
            _lastToken = token
            return _eligibilityResult
        }
        return try result.get()
    }

    func schedulePickup(_ request: SchedulePickupRequest, token: String) async throws -> PickupConfirmation {
        let result = lock.withLock { () -> Result<PickupConfirmation, Error> in
            _scheduleCallCount += 1
            _lastScheduleRequest = request
            _lastToken = token
            return _scheduleResult
        }
        return try result.get()
    }
}
