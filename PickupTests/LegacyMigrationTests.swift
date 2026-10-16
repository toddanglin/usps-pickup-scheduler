import XCTest
@testable import Pickup

final class LegacyMigrationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var newKeychain: InMemoryKeychain!
    private var legacyKeychain: InMemoryKeychain!

    override func setUp() {
        super.setUp()
        suiteName = "PickupTests.migration.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        newKeychain = InMemoryKeychain()
        legacyKeychain = InMemoryKeychain()
    }

    override func tearDown() {
        TestDefaults.remove(suiteName: suiteName)
        defaults = nil
        suiteName = nil
        newKeychain = nil
        legacyKeychain = nil
        super.tearDown()
    }

    @discardableResult
    private func migrate() -> LegacyMigration.Outcome {
        LegacyMigration.runIfNeeded(defaults: defaults,
                                    newKeychain: newKeychain,
                                    legacyKeychain: legacyKeychain)
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
        XCTAssertTrue(defaults.bool(forKey: LegacyMigration.doneKey))
    }

    func testDoesNothingWhenNewCredentialsExist() throws {
        try legacyKeychain.saveCredentials(id: "old-id", secret: "old-secret")
        try newKeychain.saveCredentials(id: "new-id", secret: "new-secret")

        let outcome = migrate()

        XCTAssertTrue(outcome.ran)
        XCTAssertFalse(outcome.migratedCredentials)
        XCTAssertEqual(try newKeychain.loadCredentials()?.id, "new-id")
        XCTAssertEqual(try legacyKeychain.loadCredentials()?.id, "old-id",
                       "legacy credentials are only deleted after a successful move")
    }

    func testNothingToMigrateStillMarksDone() throws {
        let outcome = migrate()

        XCTAssertTrue(outcome.ran)
        XCTAssertFalse(outcome.migratedCredentials)
        XCTAssertFalse(outcome.keychainError)
        XCTAssertNil(try newKeychain.loadCredentials())
        XCTAssertTrue(defaults.bool(forKey: LegacyMigration.doneKey))
    }

    func testRunsOnlyOnce() throws {
        XCTAssertTrue(migrate().ran)
        XCTAssertTrue(defaults.bool(forKey: LegacyMigration.doneKey))

        // Credentials that turn up later under the old name are not picked up.
        try legacyKeychain.saveCredentials(id: "late-id", secret: "late-secret")
        let second = migrate()

        XCTAssertFalse(second.ran)
        XCTAssertNil(try newKeychain.loadCredentials())
        XCTAssertEqual(try legacyKeychain.loadCredentials()?.id, "late-id")
    }

    func testToleratesLegacyKeychainReadError() throws {
        try legacyKeychain.saveCredentials(id: "old-id", secret: "old-secret")
        legacyKeychain.failReads = true

        let outcome = migrate()

        XCTAssertTrue(outcome.keychainError)
        XCTAssertFalse(outcome.migratedCredentials)
        XCTAssertNil(try newKeychain.loadCredentials())
        XCTAssertTrue(defaults.bool(forKey: LegacyMigration.doneKey))
        legacyKeychain.failReads = false
        XCTAssertEqual(try legacyKeychain.loadCredentials()?.id, "old-id", "nothing deleted")
    }

    func testToleratesCurrentKeychainReadError() throws {
        try legacyKeychain.saveCredentials(id: "old-id", secret: "old-secret")
        newKeychain.failReads = true

        let outcome = migrate()

        XCTAssertTrue(outcome.keychainError)
        XCTAssertFalse(outcome.migratedCredentials)
        XCTAssertTrue(defaults.bool(forKey: LegacyMigration.doneKey))
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
}
