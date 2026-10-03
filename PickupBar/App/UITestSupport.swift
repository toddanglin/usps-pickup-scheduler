import Foundation

/// Storage substitutions used only when the app is launched by `PickupBarUITests`
/// (`PICKUPBAR_UITEST=1` in the launch environment). Nothing here runs in a
/// normally launched app.
enum UITestSupport {
    /// The UserDefaults suite and Keychain service the UI test writes to, so a
    /// test run never touches the real user's saved address or credentials.
    static let storageName = "com.toddanglin.PickupBar.uitest"

    static var isActive: Bool {
        ProcessInfo.processInfo.environment["PICKUPBAR_UITEST"] == "1"
    }

    /// Start with credentials and a verified address already saved.
    static var isSeeded: Bool {
        isActive && ProcessInfo.processInfo.environment["PICKUPBAR_UITEST_SEED"] == "1"
    }
}

/// Credential storage for UI tests.
///
/// The UI test cannot use the real `KeychainStore`: a locally built PickupBar is
/// ad-hoc signed (`CODE_SIGN_IDENTITY = "-"`), and a sandboxed, ad-hoc-signed app
/// has no application-identifier entitlement, so the data-protection keychain
/// rejects `SecItemAdd` with `errSecMissingEntitlement` (-34018). Credentials
/// therefore go into the throwaway UI-test defaults suite instead, which is
/// cleared at launch. Production keeps using `KeychainStore` unchanged.
struct UITestCredentialStore: KeychainStoring {
    private static let idKey = "uitest.usps-consumer-key"
    private static let secretKey = "uitest.usps-consumer-secret"

    /// The defaults suite name rather than the `UserDefaults` itself, which is
    /// not `Sendable`.
    let suiteName: String

    private var defaults: UserDefaults { UserDefaults(suiteName: suiteName) ?? .standard }

    func loadCredentials() throws -> (id: String, secret: String)? {
        let defaults = self.defaults
        guard let id = defaults.string(forKey: Self.idKey),
              let secret = defaults.string(forKey: Self.secretKey) else { return nil }
        return (id: id, secret: secret)
    }

    func saveCredentials(id: String, secret: String) throws {
        let defaults = self.defaults
        defaults.set(id, forKey: Self.idKey)
        defaults.set(secret, forKey: Self.secretKey)
    }

    func deleteCredentials() throws {
        let defaults = self.defaults
        defaults.removeObject(forKey: Self.idKey)
        defaults.removeObject(forKey: Self.secretKey)
    }
}
