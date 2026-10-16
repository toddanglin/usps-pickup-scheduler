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

    private var _failReads = false
    private var _failDeletes = false

    /// When true, `loadCredentials` throws, like a denied Keychain prompt.
    var failReads: Bool {
        get { lock.withLock { _failReads } }
        set { lock.withLock { _failReads = newValue } }
    }

    /// When true, `deleteCredentials` throws.
    var failDeletes: Bool {
        get { lock.withLock { _failDeletes } }
        set { lock.withLock { _failDeletes = newValue } }
    }

    private let idAccount = "usps-consumer-key"
    private let secretAccount = "usps-consumer-secret"

    func loadCredentials() throws -> (id: String, secret: String)? {
        lock.lock()
        defer { lock.unlock() }
        if _failReads { throw KeychainError.osStatus(-128) }
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
        if _failDeletes { throw KeychainError.osStatus(-25293) }
        storage.removeValue(forKey: idAccount)
        storage.removeValue(forKey: secretAccount)
    }
}
