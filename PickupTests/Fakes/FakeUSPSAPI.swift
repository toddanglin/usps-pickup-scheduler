import Foundation
@testable import Pickup

/// In-memory `USPSAPI` for tests. All results default to success; set the
/// `*Result` properties to drive failures. Thread-safe via an `NSLock`, so it
/// can be handed to an actor or used from concurrent tasks.
final class FakeUSPSAPI: USPSAPI, @unchecked Sendable {
    private let lock = NSLock()

    private var _tokenResult: Result<OAuthToken, Error> =
        .success(OAuthToken(accessToken: "fake-token", expiresAt: Date().addingTimeInterval(28_799)))
    private var _eligibilityResult: Result<PostalAddress, Error> = .success(FakeUSPSAPI.defaultAddress)
    private var _eligibilityResults: [Result<PostalAddress, Error>] = []
    private var _scheduleResult: Result<PickupConfirmation, Error> =
        .success(PickupConfirmation(confirmationNumber: "ABC123", pickupDate: "2026-09-21"))
    private var _scheduleResults: [Result<PickupConfirmation, Error>] = []

    private var _fetchResult: Result<FetchedPickup, Error> = .success(FakeUSPSAPI.defaultFetched)
    private var _fetchResults: [Result<FetchedPickup, Error>] = []
    private var _updateResult: Result<FetchedPickup, Error> = .success(FakeUSPSAPI.defaultUpdated)
    private var _updateResults: [Result<FetchedPickup, Error>] = []
    private var _cancelResult: Result<Void, Error> = .success(())
    private var _cancelResults: [Result<Void, Error>] = []

    private var _fetchCallCount = 0
    private var _updateCallCount = 0
    private var _cancelCallCount = 0
    private var _lastFetchConfirmationNumber: String?
    private var _lastUpdate: (confirmationNumber: String, etag: String, request: SchedulePickupRequest)?
    private var _lastCancel: (confirmationNumber: String, etag: String)?
    private var _calls: [String] = []

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

    static let defaultFetched = FetchedPickup(
        confirmation: PickupConfirmation(confirmationNumber: "ABC123", pickupDate: "2026-09-21"),
        request: nil, etag: "fake-etag")
    static let defaultUpdated = FetchedPickup(
        confirmation: PickupConfirmation(confirmationNumber: "ABC123", pickupDate: "2026-09-21"),
        request: nil, etag: "fake-etag-updated")

    // MARK: - Configuration

    var fetchResult: Result<FetchedPickup, Error> {
        get { lock.withLock { _fetchResult } }
        set { lock.withLock { _fetchResult = newValue } }
    }

    /// Handed out by `fetchPickup`, in order, before falling back to `fetchResult`.
    var fetchResults: [Result<FetchedPickup, Error>] {
        get { lock.withLock { _fetchResults } }
        set { lock.withLock { _fetchResults = newValue } }
    }

    var updateResult: Result<FetchedPickup, Error> {
        get { lock.withLock { _updateResult } }
        set { lock.withLock { _updateResult = newValue } }
    }

    /// Handed out by `updatePickup`, in order, before falling back to `updateResult`.
    var updateResults: [Result<FetchedPickup, Error>] {
        get { lock.withLock { _updateResults } }
        set { lock.withLock { _updateResults = newValue } }
    }

    var cancelResult: Result<Void, Error> {
        get { lock.withLock { _cancelResult } }
        set { lock.withLock { _cancelResult = newValue } }
    }

    /// Handed out by `cancelPickup`, in order, before falling back to `cancelResult`.
    var cancelResults: [Result<Void, Error>] {
        get { lock.withLock { _cancelResults } }
        set { lock.withLock { _cancelResults = newValue } }
    }

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

    /// Results handed out by `checkEligibility`, in order, before falling back
    /// to `eligibilityResult`.
    var eligibilityResults: [Result<PostalAddress, Error>] {
        get { lock.withLock { _eligibilityResults } }
        set { lock.withLock { _eligibilityResults = newValue } }
    }

    /// Results handed out by `schedulePickup`, in order, before falling back
    /// to `scheduleResult`. Use it to script a failure followed by a success.
    var scheduleResults: [Result<PickupConfirmation, Error>] {
        get { lock.withLock { _scheduleResults } }
        set { lock.withLock { _scheduleResults = newValue } }
    }

    /// Artificial delay applied to `fetchToken`, useful for coalescing tests.
    var tokenDelay: TimeInterval {
        get { lock.withLock { _tokenDelay } }
        set { lock.withLock { _tokenDelay = newValue } }
    }

    // MARK: - Observations

    var fetchCallCount: Int { lock.withLock { _fetchCallCount } }
    var updateCallCount: Int { lock.withLock { _updateCallCount } }
    var cancelCallCount: Int { lock.withLock { _cancelCallCount } }
    var lastFetchConfirmationNumber: String? { lock.withLock { _lastFetchConfirmationNumber } }
    var lastUpdate: (confirmationNumber: String, etag: String, request: SchedulePickupRequest)? {
        lock.withLock { _lastUpdate }
    }
    var lastCancel: (confirmationNumber: String, etag: String)? { lock.withLock { _lastCancel } }
    /// "fetch", "update" and "cancel", in the order they were made.
    var calls: [String] { lock.withLock { _calls } }

    var tokenCallCount: Int { lock.withLock { _tokenCallCount } }
    var eligibilityCallCount: Int { lock.withLock { _eligibilityCallCount } }
    var scheduleCallCount: Int { lock.withLock { _scheduleCallCount } }
    var lastScheduleRequest: SchedulePickupRequest? { lock.withLock { _lastScheduleRequest } }
    var lastEligibilityAddress: PostalAddress? { lock.withLock { _lastEligibilityAddress } }
    var lastToken: String? { lock.withLock { _lastToken } }
    var lastCredentials: (id: String, secret: String)? { lock.withLock { _lastCredentials } }

    /// Forgets every call made so far (counts, last arguments, `calls`), and
    /// restores the default fetch result. Use it after a background check the
    /// test does not care about.
    func resetObservations() {
        lock.withLock {
            _fetchCallCount = 0
            _updateCallCount = 0
            _cancelCallCount = 0
            _lastFetchConfirmationNumber = nil
            _lastUpdate = nil
            _lastCancel = nil
            _calls = []
            _fetchResult = .success(FakeUSPSAPI.defaultFetched)
            _fetchResults = []
        }
    }

    /// Convenience: a token that expires `seconds` from `now`.
    func setToken(_ accessToken: String = "fake-token", expiresIn seconds: TimeInterval,
                  from now: Date = Date(), scopes: [String] = [], apiProducts: String? = nil) {
        tokenResult = .success(OAuthToken(accessToken: accessToken,
                                          expiresAt: now.addingTimeInterval(seconds),
                                          scopes: scopes,
                                          apiProducts: apiProducts))
    }

    /// Convenience: keep the default token but give it `scopes`.
    func setScopes(_ scopes: [String]) {
        setToken(expiresIn: 28_799, scopes: scopes)
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
            return _eligibilityResults.isEmpty ? _eligibilityResult : _eligibilityResults.removeFirst()
        }
        return try result.get()
    }

    func schedulePickup(_ request: SchedulePickupRequest, token: String) async throws -> PickupConfirmation {
        let result = lock.withLock { () -> Result<PickupConfirmation, Error> in
            _scheduleCallCount += 1
            _lastScheduleRequest = request
            _lastToken = token
            return _scheduleResults.isEmpty ? _scheduleResult : _scheduleResults.removeFirst()
        }
        return try result.get()
    }

    func fetchPickup(confirmationNumber: String, token: String) async throws -> FetchedPickup {
        let result = lock.withLock { () -> Result<FetchedPickup, Error> in
            _fetchCallCount += 1
            _calls.append("fetch")
            _lastFetchConfirmationNumber = confirmationNumber
            _lastToken = token
            return _fetchResults.isEmpty ? _fetchResult : _fetchResults.removeFirst()
        }
        return try result.get()
    }

    func updatePickup(confirmationNumber: String, etag: String, request: SchedulePickupRequest,
                      token: String) async throws -> FetchedPickup {
        let result = lock.withLock { () -> Result<FetchedPickup, Error> in
            _updateCallCount += 1
            _calls.append("update")
            _lastUpdate = (confirmationNumber: confirmationNumber, etag: etag, request: request)
            _lastToken = token
            return _updateResults.isEmpty ? _updateResult : _updateResults.removeFirst()
        }
        return try result.get()
    }

    func cancelPickup(confirmationNumber: String, etag: String, token: String) async throws {
        let result = lock.withLock { () -> Result<Void, Error> in
            _cancelCallCount += 1
            _calls.append("cancel")
            _lastCancel = (confirmationNumber: confirmationNumber, etag: etag)
            _lastToken = token
            return _cancelResults.isEmpty ? _cancelResult : _cancelResults.removeFirst()
        }
        try result.get()
    }
}
