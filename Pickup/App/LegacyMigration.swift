import Foundation
import os

/// One-time move of a PickupBar install's data to Pickup.
///
/// The app was called PickupBar (bundle id `com.toddanglin.PickupBar`) until
/// 1.0.1. A new bundle id means a new sandbox container and a new Keychain
/// service, so without this an existing user would land on onboarding with
/// their address, defaults and pickup history gone.
///
/// - Settings: the `settings.v1` blob is copied as raw data, before
///   `SettingsStore` is built, so the store simply loads it. The legacy copy is
///   left in place (harmless, and lets the user go back to PickupBar).
/// - Credentials: read from the legacy Keychain service, saved under the new
///   one, then deleted from the legacy one. The legacy items' access list names
///   the old app, so macOS shows one Keychain prompt for this read.
///
/// Runs once: `doneKey` is recorded in the new defaults whatever happened.
/// Never runs under the UI test or as the unit-test host.
enum LegacyMigration {
    static let legacyIdentifier = "com.toddanglin.PickupBar"
    static let doneKey = "migration.legacyPickupBar.done"
    static let settingsKey = "settings.v1"

    private static let logger = Logger(subsystem: "com.toddanglin.Pickup", category: "migration")

    /// What a run did, for tests and the log line.
    struct Outcome: Equatable {
        var ran = false
        var migratedSettings = false
        var migratedCredentials = false
        /// A Keychain call failed; the migration carried on without it.
        var keychainError = false
    }

    /// Launch entry point: the real defaults and Keychain, plus the legacy
    /// app's. Call before constructing `SettingsStore`.
    @discardableResult
    static func runIfNeeded(defaults: UserDefaults = .standard,
                            keychain: KeychainStoring,
                            legacyDefaultsSuite: String = legacyIdentifier,
                            legacyKeychainService: String = legacyIdentifier) -> Outcome {
        runIfNeeded(newDefaults: defaults,
                    legacySettings: { legacySettingsData(suite: legacyDefaultsSuite) },
                    newKeychain: keychain,
                    legacyKeychain: KeychainStore(service: legacyKeychainService))
    }

    /// Variant whose legacy settings live in a `UserDefaults` the caller owns.
    @discardableResult
    static func runIfNeeded(newDefaults: UserDefaults,
                            legacyDefaults: UserDefaults?,
                            newKeychain: KeychainStoring,
                            legacyKeychain: KeychainStoring) -> Outcome {
        runIfNeeded(newDefaults: newDefaults,
                    legacySettings: { legacyDefaults?.data(forKey: settingsKey) },
                    newKeychain: newKeychain,
                    legacyKeychain: legacyKeychain)
    }

    @discardableResult
    static func runIfNeeded(newDefaults: UserDefaults,
                            legacySettings: () -> Data?,
                            newKeychain: KeychainStoring,
                            legacyKeychain: KeychainStoring) -> Outcome {
        var outcome = Outcome()
        guard !newDefaults.bool(forKey: doneKey) else { return outcome }
        outcome.ran = true

        if newDefaults.data(forKey: settingsKey) == nil, let data = legacySettings() {
            newDefaults.set(data, forKey: settingsKey)
            outcome.migratedSettings = true
        }

        migrateCredentials(from: legacyKeychain, to: newKeychain, outcome: &outcome)

        newDefaults.set(true, forKey: doneKey)
        let summary = "PickupBar migration: settings \(outcome.migratedSettings ? "copied" : "not copied"), "
            + "credentials \(outcome.migratedCredentials ? "moved" : "not moved")"
            + (outcome.keychainError ? " (Keychain error, see above)" : "")
        logger.log("\(summary, privacy: .public)")
        return outcome
    }

    private static func migrateCredentials(from legacy: KeychainStoring,
                                           to current: KeychainStoring,
                                           outcome: inout Outcome) {
        do {
            guard try current.loadCredentials() == nil else { return }
        } catch {
            // Unreadable new item: leave both alone rather than overwrite it.
            logger.error("PickupBar migration: could not read current credentials: \(String(describing: error), privacy: .public)")
            outcome.keychainError = true
            return
        }

        let old: (id: String, secret: String)?
        do {
            old = try legacy.loadCredentials()
        } catch {
            // Includes the user denying the Keychain prompt. They can re-enter
            // the key and secret in onboarding.
            logger.error("PickupBar migration: could not read legacy credentials: \(String(describing: error), privacy: .public)")
            outcome.keychainError = true
            return
        }
        guard let old else { return }

        do {
            try current.saveCredentials(id: old.id, secret: old.secret)
        } catch {
            // Keep the legacy copy: it is the only one.
            logger.error("PickupBar migration: could not save credentials: \(String(describing: error), privacy: .public)")
            outcome.keychainError = true
            return
        }
        outcome.migratedCredentials = true

        do {
            try legacy.deleteCredentials()
        } catch {
            logger.error("PickupBar migration: could not delete legacy credentials: \(String(describing: error), privacy: .public)")
            outcome.keychainError = true
        }
    }

    // MARK: - Reading the legacy settings

    /// PickupBar's `settings.v1`, from wherever this process can see it.
    ///
    /// Both apps are sandboxed, so `UserDefaults(suiteName:)` here reads a
    /// plist inside *Pickup's* container, not PickupBar's. That lookup is tried
    /// first (it is what an unsandboxed build sees); then the plist inside
    /// PickupBar's container is read directly, which the read-only
    /// `temporary-exception.files.home-relative-path` entitlement in
    /// `project.yml` allows. macOS may ask the user to let Pickup access
    /// another app's data.
    static func legacySettingsData(suite: String) -> Data? {
        if let data = UserDefaults(suiteName: suite)?.data(forKey: settingsKey) {
            return data
        }
        guard let home = realHomeDirectory() else { return nil }
        return settingsData(inPlistAt: legacyContainerPlist(home: home, suite: suite))
    }

    /// `~/Library/Containers/<suite>/Data/Library/Preferences/<suite>.plist`.
    static func legacyContainerPlist(home: URL, suite: String) -> URL {
        home.appendingPathComponent("Library/Containers/\(suite)/Data/Library/Preferences/\(suite).plist")
    }

    static func settingsData(inPlistAt url: URL) -> Data? {
        guard let raw = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: raw, format: nil),
              let dict = plist as? [String: Any] else { return nil }
        return dict[settingsKey] as? Data
    }

    /// The user's home folder. In a sandboxed process `NSHomeDirectory()` is
    /// the container, so ask the password database instead.
    private static func realHomeDirectory() -> URL? {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }
}
