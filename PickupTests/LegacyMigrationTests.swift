import XCTest
@testable import Pickup

@MainActor
final class LegacyMigrationTests: XCTestCase {
    private var newSuite: String!
    private var legacySuite: String!
    private var newDefaults: UserDefaults!
    private var legacyDefaults: UserDefaults!
    private var newKeychain: InMemoryKeychain!
    private var legacyKeychain: InMemoryKeychain!

    override func setUp() {
        super.setUp()
        newSuite = "PickupTests.migration-new.\(UUID().uuidString)"
        legacySuite = "PickupTests.migration-legacy.\(UUID().uuidString)"
        newDefaults = UserDefaults(suiteName: newSuite)!
        legacyDefaults = UserDefaults(suiteName: legacySuite)!
        newKeychain = InMemoryKeychain()
        legacyKeychain = InMemoryKeychain()
    }

    override func tearDown() {
        newDefaults.removePersistentDomain(forName: newSuite)
        legacyDefaults.removePersistentDomain(forName: legacySuite)
        newDefaults = nil
        legacyDefaults = nil
        newKeychain = nil
        legacyKeychain = nil
        super.tearDown()
    }

    @discardableResult
    private func migrate() -> LegacyMigration.Outcome {
        LegacyMigration.runIfNeeded(newDefaults: newDefaults,
                                    legacyDefaults: legacyDefaults,
                                    newKeychain: newKeychain,
                                    legacyKeychain: legacyKeychain)
    }

    /// A real `settings.v1` blob, written by a `SettingsStore`.
    private func writeLegacySettings(city: String = "WASHINGTON") {
        let store = SettingsStore(defaults: legacyDefaults)
        store.contact = PickupContact(firstName: "Ada", lastName: "Lovelace", firm: nil,
                                      phone: "2025550123", email: "ada@example.com")
        store.address = PostalAddress(streetAddress: "475 LENFANT PLZ SW", secondaryAddress: nil,
                                      city: city, state: "DC", ZIPCode: "20260", ZIPPlus4: nil)
        store.defaultWeight = 7
    }

    func testMigratesSettingsAndKeepsLegacyCopy() {
        writeLegacySettings()
        let legacyData = legacyDefaults.data(forKey: LegacyMigration.settingsKey)
        XCTAssertNotNil(legacyData)

        let outcome = migrate()

        XCTAssertTrue(outcome.migratedSettings)
        XCTAssertEqual(newDefaults.data(forKey: LegacyMigration.settingsKey), legacyData)
        XCTAssertEqual(legacyDefaults.data(forKey: LegacyMigration.settingsKey), legacyData,
                       "the legacy copy is left in place")
        let store = SettingsStore(defaults: newDefaults)
        XCTAssertEqual(store.address?.city, "WASHINGTON")
        XCTAssertEqual(store.contact?.firstName, "Ada")
        XCTAssertEqual(store.defaultWeight, 7)
        XCTAssertTrue(store.isAddressConfigured)
    }

    func testMigratesCredentialsAndDeletesLegacyItems() throws {
        try legacyKeychain.saveCredentials(id: "old-id", secret: "old-secret")

        let outcome = migrate()

        XCTAssertTrue(outcome.migratedCredentials)
        XCTAssertFalse(outcome.keychainError)
        let moved = try XCTUnwrap(try newKeychain.loadCredentials())
        XCTAssertEqual(moved.id, "old-id")
        XCTAssertEqual(moved.secret, "old-secret")
        XCTAssertNil(try legacyKeychain.loadCredentials())
    }

    func testDoesNothingWhenNewDataExists() throws {
        writeLegacySettings(city: "OLDTOWN")
        try legacyKeychain.saveCredentials(id: "old-id", secret: "old-secret")
        let current = Data("{}".utf8)
        newDefaults.set(current, forKey: LegacyMigration.settingsKey)
        try newKeychain.saveCredentials(id: "new-id", secret: "new-secret")

        let outcome = migrate()

        XCTAssertTrue(outcome.ran)
        XCTAssertFalse(outcome.migratedSettings)
        XCTAssertFalse(outcome.migratedCredentials)
        XCTAssertEqual(newDefaults.data(forKey: LegacyMigration.settingsKey), current)
        XCTAssertEqual(try newKeychain.loadCredentials()?.id, "new-id")
        XCTAssertEqual(try legacyKeychain.loadCredentials()?.id, "old-id",
                       "legacy credentials are only deleted after a successful move")
    }

    func testNothingToMigrateStillMarksDone() {
        let outcome = migrate()

        XCTAssertTrue(outcome.ran)
        XCTAssertFalse(outcome.migratedSettings)
        XCTAssertFalse(outcome.migratedCredentials)
        XCTAssertNil(newDefaults.data(forKey: LegacyMigration.settingsKey))
        XCTAssertTrue(newDefaults.bool(forKey: LegacyMigration.doneKey))
    }

    func testRunsOnlyOnce() throws {
        XCTAssertTrue(migrate().ran)
        XCTAssertTrue(newDefaults.bool(forKey: LegacyMigration.doneKey))

        // Data that turns up later under the old name is not picked up.
        writeLegacySettings()
        try legacyKeychain.saveCredentials(id: "late-id", secret: "late-secret")
        let second = migrate()

        XCTAssertFalse(second.ran)
        XCTAssertNil(newDefaults.data(forKey: LegacyMigration.settingsKey))
        XCTAssertNil(try newKeychain.loadCredentials())
        XCTAssertEqual(try legacyKeychain.loadCredentials()?.id, "late-id")
    }

    func testToleratesLegacyKeychainReadError() throws {
        writeLegacySettings()
        try legacyKeychain.saveCredentials(id: "old-id", secret: "old-secret")
        legacyKeychain.failReads = true

        let outcome = migrate()

        XCTAssertTrue(outcome.keychainError)
        XCTAssertFalse(outcome.migratedCredentials)
        XCTAssertTrue(outcome.migratedSettings, "settings still move")
        XCTAssertNil(try newKeychain.loadCredentials())
        XCTAssertTrue(newDefaults.bool(forKey: LegacyMigration.doneKey))
        legacyKeychain.failReads = false
        XCTAssertEqual(try legacyKeychain.loadCredentials()?.id, "old-id", "nothing deleted")
    }

    func testKeepsLegacyCredentialsWhenSaveFails() throws {
        try legacyKeychain.saveCredentials(id: "old-id", secret: "old-secret")
        newKeychain.failWrites = true

        let outcome = migrate()

        XCTAssertTrue(outcome.keychainError)
        XCTAssertFalse(outcome.migratedCredentials)
        XCTAssertEqual(try legacyKeychain.loadCredentials()?.id, "old-id")
    }

    func testDeleteFailureStillCountsAsMigrated() throws {
        try legacyKeychain.saveCredentials(id: "old-id", secret: "old-secret")
        legacyKeychain.failDeletes = true

        let outcome = migrate()

        XCTAssertTrue(outcome.migratedCredentials)
        XCTAssertTrue(outcome.keychainError)
        XCTAssertEqual(try newKeychain.loadCredentials()?.id, "old-id")
    }

    /// The sandboxed app cannot see PickupBar's defaults through
    /// `UserDefaults(suiteName:)`, so the launch path reads the legacy
    /// container's plist file directly.
    func testReadsSettingsFromLegacyContainerPlist() throws {
        writeLegacySettings()
        let blob = try XCTUnwrap(legacyDefaults.data(forKey: LegacyMigration.settingsKey))

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let plistURL = LegacyMigration.legacyContainerPlist(home: home, suite: "com.example.Old")
        XCTAssertTrue(plistURL.path.hasSuffix(
            "Library/Containers/com.example.Old/Data/Library/Preferences/com.example.Old.plist"))
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [LegacyMigration.settingsKey: blob, "other": 1], format: .binary, options: 0)
        try plist.write(to: plistURL)

        XCTAssertEqual(LegacyMigration.settingsData(inPlistAt: plistURL), blob)
        XCTAssertNil(LegacyMigration.settingsData(inPlistAt: home.appendingPathComponent("missing.plist")))

        let outcome = LegacyMigration.runIfNeeded(
            newDefaults: newDefaults,
            legacySettings: { LegacyMigration.settingsData(inPlistAt: plistURL) },
            newKeychain: newKeychain,
            legacyKeychain: legacyKeychain)
        XCTAssertTrue(outcome.migratedSettings)
        XCTAssertEqual(SettingsStore(defaults: newDefaults).address?.city, "WASHINGTON")
    }
}
