import Foundation
import Security

protocol KeychainStoring: Sendable {
    func loadCredentials() throws -> (id: String, secret: String)?
    func saveCredentials(id: String, secret: String) throws
    func deleteCredentials() throws
}

enum KeychainError: Error, Equatable {
    case osStatus(OSStatus)
    case badData
}

struct KeychainStore: KeychainStoring {
    var service = "com.toddanglin.Pickup"

    private let idAccount = "usps-consumer-key"
    private let secretAccount = "usps-consumer-secret"

    func loadCredentials() throws -> (id: String, secret: String)? {
        guard let id = try read(account: idAccount),
              let secret = try read(account: secretAccount) else {
            return nil
        }
        return (id: id, secret: secret)
    }

    func saveCredentials(id: String, secret: String) throws {
        try write(account: idAccount, value: id)
        try write(account: secretAccount, value: secret)
    }

    func deleteCredentials() throws {
        try delete(account: idAccount)
        try delete(account: secretAccount)
    }

    // MARK: - Private helpers

    private func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.osStatus(status)
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.badData
        }
        return value
    }

    private func write(account: String, value: String) throws {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery(account: account)
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.osStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.osStatus(updateStatus)
        }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }

    /// Deliberately does *not* set `kSecUseDataProtectionKeychain`: the
    /// data-protection keychain requires a keychain-access-group entitlement,
    /// which an ad-hoc-signed sandboxed build (how Pickup is built from
    /// source) does not have, so `SecItemAdd` fails with
    /// `errSecMissingEntitlement` (-34018). The default file-based keychain
    /// works in every configuration; `kSecAttrAccessibleAfterFirstUnlock` on
    /// add is simply ignored there.
    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
