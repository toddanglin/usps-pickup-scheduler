import XCTest
@testable import PickupBar

/// Exercises the *real* Keychain from inside the sandboxed, ad-hoc-signed test
/// host — the exact configuration where `kSecUseDataProtectionKeychain` used to
/// make `SecItemAdd` fail with `errSecMissingEntitlement` (-34018).
final class KeychainStoreTests: XCTestCase {
    private let store = KeychainStore(service: "com.toddanglin.PickupBar.tests")

    override func setUp() {
        super.setUp()
        try? store.deleteCredentials()
    }

    override func tearDown() {
        try? store.deleteCredentials()
        super.tearDown()
    }

    func testSaveLoadDeleteRoundTrip() throws {
        do {
            try store.saveCredentials(id: "consumer-key", secret: "consumer-secret")
        } catch KeychainError.osStatus(let status) {
            return XCTFail("SecItem write failed with OSStatus \(status)")
        }

        let loaded = try store.loadCredentials()
        XCTAssertEqual(loaded?.id, "consumer-key")
        XCTAssertEqual(loaded?.secret, "consumer-secret")

        // A second save must update in place rather than fail on a duplicate.
        try store.saveCredentials(id: "consumer-key-2", secret: "consumer-secret-2")
        XCTAssertEqual(try store.loadCredentials()?.id, "consumer-key-2")
        XCTAssertEqual(try store.loadCredentials()?.secret, "consumer-secret-2")

        try store.deleteCredentials()
        XCTAssertNil(try store.loadCredentials())
    }

    func testDeleteIsIdempotent() throws {
        XCTAssertNoThrow(try store.deleteCredentials())
        XCTAssertNoThrow(try store.deleteCredentials())
    }
}
