import Foundation
@testable import Pickup

/// Dictionary-backed fake conforming to `KeychainStoring`, for use by tests
/// that need credential storage without touching the real Keychain.
final class InMemoryKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]
    private var _failWrites = false

    /// When true, `saveCredentials` throws `errSecMissingEntitlement`, standing
    /// in for a Keychain that refuses to store anything.
    var failWrites: Bool {
        get { lock.withLock { _failWrites } }
        set { lock.withLock { _failWrites = newValue } }
    }

    private let idAccount = "usps-consumer-key"
    private let secretAccount = "usps-consumer-secret"

    func loadCredentials() throws -> (id: String, secret: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard let id = storage[idAccount], let secret = storage[secretAccount] else {
            return nil
        }
        return (id: id, secret: secret)
    }

    func saveCredentials(id: String, secret: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if _failWrites { throw KeychainError.osStatus(-34018) }
        storage[idAccount] = id
        storage[secretAccount] = secret
    }

    func deleteCredentials() throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: idAccount)
        storage.removeValue(forKey: secretAccount)
    }
}
