import Foundation

/// Caches the USPS access token and refreshes it just before expiry.
///
/// Concurrent callers share a single in-flight refresh, so a burst of requests
/// at launch produces one token call.
actor TokenManager {
    /// Refresh when the cached token has less than this long to live.
    private static let refreshMargin: TimeInterval = 60

    private var api: USPSAPI
    private let credentials: @Sendable () -> (id: String, secret: String)?
    private let now: @Sendable () -> Date

    private var cached: OAuthToken?
    private var inFlight: Task<OAuthToken, Error>?

    init(api: USPSAPI,
         credentials: @escaping @Sendable () -> (id: String, secret: String)?,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api
        self.credentials = credentials
        self.now = now
    }

    /// Returns a usable access token, fetching a new one when the cache is
    /// empty or about to expire.
    func validToken() async throws -> String {
        if let cached, cached.expiresAt.timeIntervalSince(now()) > Self.refreshMargin {
            return cached.accessToken
        }
        if let inFlight {
            return try await inFlight.value.accessToken
        }

        guard let credentials = credentials() else { throw USPSError.invalidCredentials }

        let api = self.api
        let task = Task<OAuthToken, Error> {
            try await api.fetchToken(clientID: credentials.id, clientSecret: credentials.secret)
        }
        inFlight = task

        do {
            let token = try await task.value
            finish(task, with: token)
            return token.accessToken
        } catch {
            finish(task, with: nil)
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
    /// fetch was running.
    private func finish(_ task: Task<OAuthToken, Error>, with token: OAuthToken?) {
        guard inFlight == task else { return }
        inFlight = nil
        cached = token
    }
}
