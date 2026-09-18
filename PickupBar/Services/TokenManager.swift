import Foundation

/// Caches the USPS access token and refreshes it just before expiry.
///
/// Concurrent callers share a single in-flight refresh, so a burst of requests
/// at launch produces one token call.
actor TokenManager {
    /// Refresh when the cached token has less than this long to live.
    private static let refreshMargin: TimeInterval = 60

    /// A cached token plus the consumer key it was issued for, so a credential
    /// swap cannot be served a token belonging to the previous app.
    private struct CachedToken {
        var token: OAuthToken
        var credentialID: String
    }

    private var api: USPSAPI
    private let credentials: @Sendable () -> (id: String, secret: String)?
    private let now: @Sendable () -> Date

    private var cached: CachedToken?
    private var inFlight: Task<OAuthToken, Error>?

    init(api: USPSAPI,
         credentials: @escaping @Sendable () -> (id: String, secret: String)?,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api
        self.credentials = credentials
        self.now = now
    }

    /// Returns a usable access token, fetching a new one when the cache is
    /// empty, stale (issued for different credentials), or about to expire.
    func validToken() async throws -> String {
        // Credentials are read on every call: they can be replaced or removed
        // while the app is running.
        guard let credentials = credentials() else { throw USPSError.invalidCredentials }

        if let cached, cached.credentialID != credentials.id {
            self.cached = nil
            inFlight = nil
        }
        if let cached, cached.token.expiresAt.timeIntervalSince(now()) > Self.refreshMargin {
            return cached.token.accessToken
        }
        if let inFlight {
            return try await inFlight.value.accessToken
        }

        let api = self.api
        let task = Task<OAuthToken, Error> {
            try await api.fetchToken(clientID: credentials.id, clientSecret: credentials.secret)
        }
        inFlight = task

        do {
            let token = try await task.value
            finish(task, with: CachedToken(token: token, credentialID: credentials.id))
            return token.accessToken
        } catch {
            // A failed refresh only invalidates the attempt, not the token we
            // already hold: if it has not expired yet, it is still usable.
            finish(task, with: nil)
            if let cached, cached.token.expiresAt > now() {
                return cached.token.accessToken
            }
            throw error
        }
    }

    /// Drops the cached token so the next `validToken()` refetches.
    func invalidate() {
        cached = nil
        inFlight = nil
    }

    /// Swaps in a new API client (for example when the base URL changes) and
    /// drops the cached token, which belonged to the old environment.
    func replaceAPI(_ api: USPSAPI) {
        self.api = api
        invalidate()
    }

    /// Clears the in-flight task, but only when it is still the current one —
    /// `invalidate()` or `replaceAPI(_:)` may have superseded it while the
    /// fetch was running. A non-nil `token` also replaces the cache; `nil`
    /// leaves whatever is cached in place.
    private func finish(_ task: Task<OAuthToken, Error>, with token: CachedToken?) {
        guard inFlight == task else { return }
        inFlight = nil
        if let token { cached = token }
    }
}
