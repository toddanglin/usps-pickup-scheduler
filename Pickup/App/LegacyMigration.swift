import Foundation
import os

/// One-time move of a PickupBar install's USPS credentials to Pickup.
///
/// The app was called PickupBar (bundle id `com.toddanglin.PickupBar`) until
/// 1.0.1, and kept the Consumer Key and Secret under that Keychain service.
/// This reads them from the legacy service, saves them under the new one, then
/// deletes the legacy items. The legacy items' access list names the old app,
/// so macOS shows a Keychain prompt for the read.
///
/// Settings are not migrated: a new bundle id means a new sandbox container,
/// and reading the old one would need a sandbox file-read exception. PickupBar
/// was only ever built from source, so its users re-enter their address once.
///
/// Runs once: `doneKey` is recorded in the defaults whatever happened. Never
/// runs under the UI test or as the unit-test host.
enum LegacyMigration {
    static let legacyKeychainService = "com.toddanglin.PickupBar"
    static let doneKey = "migration.legacyPickupBar.done"

    private static let logger = Logger(subsystem: "com.toddanglin.Pickup", category: "migration")

    /// What a run did, for tests and the log line.
    struct Outcome: Equatable {
        var ran = false
        var migratedCredentials = false
        /// A Keychain call failed; the migration carried on without it.
        var keychainError = false
    }

    /// Launch entry point: the real defaults and Keychain, plus the legacy
    /// Keychain service.
    @discardableResult
    static func runIfNeeded(defaults: UserDefaults = .standard,
                            keychain: KeychainStoring,
                            legacyKeychainService: String = legacyKeychainService) -> Outcome {
        runIfNeeded(defaults: defaults,
                    newKeychain: keychain,
                    legacyKeychain: KeychainStore(service: legacyKeychainService))
    }

    @discardableResult
    static func runIfNeeded(defaults: UserDefaults,
                            newKeychain: KeychainStoring,
                            legacyKeychain: KeychainStoring) -> Outcome {
        var outcome = Outcome()
        guard !defaults.bool(forKey: doneKey) else { return outcome }
        outcome.ran = true

        migrateCredentials(from: legacyKeychain, to: newKeychain, outcome: &outcome)

        defaults.set(true, forKey: doneKey)
        let summary = "PickupBar migration: credentials \(outcome.migratedCredentials ? "moved" : "not moved")"
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
}
