import XCTest
@testable import PickupBar

final class TokenManagerTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

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
