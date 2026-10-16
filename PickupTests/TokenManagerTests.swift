import XCTest
@testable import Pickup

final class TokenManagerTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    /// Mutable clock and credentials, so tests can move time forward or swap
    /// the stored consumer key between calls.
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Value
        init(_ value: Value) { _value = value }
        var value: Value {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    private func makeManager(api: FakeUSPSAPI,
                             credentials: (id: String, secret: String)? = ("key", "secret"),
                             now: Date? = nil) -> TokenManager {
        let then = now ?? fixedNow
        return TokenManager(api: api, credentials: { credentials }, now: { then })
    }

    func testFirstCallFetchesToken() async throws {
        let api = FakeUSPSAPI()
        api.setToken("tok-1", expiresIn: 3600, from: fixedNow)
        let manager = makeManager(api: api)

        let token = try await manager.validToken()
        XCTAssertEqual(token, "tok-1")
        XCTAssertEqual(api.tokenCallCount, 1)
        XCTAssertEqual(api.lastCredentials?.id, "key")
        XCTAssertEqual(api.lastCredentials?.secret, "secret")
    }

    func testCurrentScopesComeFromTheCachedToken() async throws {
        let api = FakeUSPSAPI()
        api.setToken("tok-1", expiresIn: 3600, from: fixedNow, scopes: ["addresses", "pickup"])
        let manager = makeManager(api: api)

        let beforeFetch = await manager.currentScopes()
        XCTAssertEqual(beforeFetch, [], "no token yet means no known scopes")

        _ = try await manager.validToken()
        let scopes = await manager.currentScopes()
        XCTAssertEqual(scopes, ["addresses", "pickup"])

        await manager.invalidate()
        let cleared = await manager.currentScopes()
        XCTAssertEqual(cleared, [])
    }

    func testSecondCallUsesCachedToken() async throws {
        let api = FakeUSPSAPI()
        api.setToken("tok-1", expiresIn: 3600, from: fixedNow)
        let manager = makeManager(api: api)

        _ = try await manager.validToken()
        let second = try await manager.validToken()

        XCTAssertEqual(second, "tok-1")
        XCTAssertEqual(api.tokenCallCount, 1)
    }

    func testTokenExpiringWithinSixtySecondsIsRefetched() async throws {
        let api = FakeUSPSAPI()
        api.setToken("tok-soon", expiresIn: 30, from: fixedNow)
        let manager = makeManager(api: api)

        _ = try await manager.validToken()
        api.setToken("tok-fresh", expiresIn: 3600, from: fixedNow)
        let second = try await manager.validToken()

        XCTAssertEqual(second, "tok-fresh")
        XCTAssertEqual(api.tokenCallCount, 2)
    }

    func testInvalidateForcesRefetch() async throws {
        let api = FakeUSPSAPI()
        api.setToken("tok-1", expiresIn: 3600, from: fixedNow)
        let manager = makeManager(api: api)

        _ = try await manager.validToken()
        await manager.invalidate()
        _ = try await manager.validToken()

        XCTAssertEqual(api.tokenCallCount, 2)
    }

    func testMissingCredentialsThrowsWithoutCallingAPI() async {
        let api = FakeUSPSAPI()
        let manager = makeManager(api: api, credentials: nil)

        do {
            _ = try await manager.validToken()
            XCTFail("expected invalidCredentials")
        } catch let error as USPSError {
            XCTAssertEqual(error, .invalidCredentials)
        } catch {
            XCTFail("expected USPSError, got \(error)")
        }
        XCTAssertEqual(api.tokenCallCount, 0)
    }

    func testConcurrentCallsCoalesceIntoOneFetch() async throws {
        let api = FakeUSPSAPI()
        api.setToken("tok-shared", expiresIn: 3600, from: fixedNow)
        api.tokenDelay = 0.2
        let manager = makeManager(api: api)

        async let first = manager.validToken()
        async let second = manager.validToken()
        async let third = manager.validToken()
        let tokens = try await [first, second, third]

        XCTAssertEqual(tokens, ["tok-shared", "tok-shared", "tok-shared"])
        XCTAssertEqual(api.tokenCallCount, 1)
    }

    func testFailedFetchPropagatesAndDoesNotCache() async {
        let api = FakeUSPSAPI()
        api.tokenResult = .failure(USPSError.invalidCredentials)
        let manager = makeManager(api: api)

        do {
            _ = try await manager.validToken()
            XCTFail("expected failure")
        } catch let error as USPSError {
            XCTAssertEqual(error, .invalidCredentials)
        } catch {
            XCTFail("expected USPSError, got \(error)")
        }

        api.setToken("tok-recovered", expiresIn: 3600, from: fixedNow)
        let recovered = try? await manager.validToken()
        XCTAssertEqual(recovered, "tok-recovered")
        XCTAssertEqual(api.tokenCallCount, 2)
    }

    func testChangedCredentialIDDiscardsCachedToken() async throws {
        let api = FakeUSPSAPI()
        api.setToken("tok-old", expiresIn: 3600, from: fixedNow)
        let credentials = Box<(id: String, secret: String)?>(("old-key", "old-secret"))
        let then = fixedNow
        let manager = TokenManager(api: api, credentials: { credentials.value }, now: { then })

        let first = try await manager.validToken()
        XCTAssertEqual(first, "tok-old")
        XCTAssertEqual(api.tokenCallCount, 1)

        credentials.value = ("new-key", "new-secret")
        api.setToken("tok-new", expiresIn: 3600, from: fixedNow)

        let second = try await manager.validToken()
        XCTAssertEqual(second, "tok-new")
        XCTAssertEqual(api.tokenCallCount, 2)
        XCTAssertEqual(api.lastCredentials?.id, "new-key")
    }

    func testCredentialsRemovedWhileCachedThrowsInvalidCredentials() async throws {
        let api = FakeUSPSAPI()
        api.setToken("tok-1", expiresIn: 3600, from: fixedNow)
        let credentials = Box<(id: String, secret: String)?>(("key", "secret"))
        let then = fixedNow
        let manager = TokenManager(api: api, credentials: { credentials.value }, now: { then })

        _ = try await manager.validToken()
        credentials.value = nil

        do {
            _ = try await manager.validToken()
            XCTFail("expected invalidCredentials")
        } catch let error as USPSError {
            XCTAssertEqual(error, .invalidCredentials)
        } catch {
            XCTFail("expected USPSError, got \(error)")
        }
        XCTAssertEqual(api.tokenCallCount, 1)
    }

    func testFailedRefreshKeepsStillValidCachedToken() async throws {
        let api = FakeUSPSAPI()
        api.setToken("tok-1", expiresIn: 300, from: fixedNow)
        let clock = Box(fixedNow)
        let manager = TokenManager(api: api, credentials: { ("key", "secret") },
                                   now: { clock.value })

        let first = try await manager.validToken()
        XCTAssertEqual(first, "tok-1")
        XCTAssertEqual(api.tokenCallCount, 1)

        // Inside the 60 s refresh margin, but the token has not expired.
        clock.value = fixedNow.addingTimeInterval(270)
        api.tokenResult = .failure(USPSError.offline)

        let afterFailedRefresh = try await manager.validToken()
        XCTAssertEqual(afterFailedRefresh, "tok-1")
        XCTAssertEqual(api.tokenCallCount, 2)

        // Once it really expires, the refresh failure surfaces.
        clock.value = fixedNow.addingTimeInterval(400)
        do {
            _ = try await manager.validToken()
            XCTFail("expected offline")
        } catch let error as USPSError {
            XCTAssertEqual(error, .offline)
        } catch {
            XCTFail("expected USPSError, got \(error)")
        }
    }

    func testReplaceAPISwapsClientAndDropsCache() async throws {
        let first = FakeUSPSAPI()
        first.setToken("tok-first", expiresIn: 3600, from: fixedNow)
        let manager = makeManager(api: first)
        let firstToken = try await manager.validToken()
        XCTAssertEqual(firstToken, "tok-first")

        let second = FakeUSPSAPI()
        second.setToken("tok-second", expiresIn: 3600, from: fixedNow)
        await manager.replaceAPI(second)

        let secondToken = try await manager.validToken()
        XCTAssertEqual(secondToken, "tok-second")
        XCTAssertEqual(first.tokenCallCount, 1)
        XCTAssertEqual(second.tokenCallCount, 1)
    }
}
