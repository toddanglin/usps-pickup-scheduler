import XCTest
@testable import PickupBar

@MainActor
final class SettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PickupBarTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaults() {
        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.defaultLocation, .frontDoor)
        XCTAssertEqual(store.defaultWeight, 1)
        XCTAssertEqual(store.defaultInstructions, "")
        XCTAssertFalse(store.dogPresent)
        XCTAssertFalse(store.useTestEnvironment)
        XCTAssertNil(store.address)
        XCTAssertNil(store.contact)
        XCTAssertNil(store.lastConfirmation)
        XCTAssertFalse(store.isAddressConfigured)
    }

    func testPersistsAcrossInstances() {
        let store = SettingsStore(defaults: defaults)

        store.defaultLocation = .mailbox
        store.address = PostalAddress(streetAddress: "123 Main St", secondaryAddress: nil, city: "Springfield", state: "IL", ZIPCode: "62701", ZIPPlus4: nil)
        store.contact = PickupContact(firstName: "Todd", lastName: "Anglin", firm: nil, phone: "5551234567", email: "todd@example.com")
        store.defaultWeight = 2.5
        store.lastConfirmation = PickupConfirmation(confirmationNumber: "WTC1", pickupDate: "2026-09-19")

        let store2 = SettingsStore(defaults: defaults)

        XCTAssertEqual(store2.defaultLocation, .mailbox)
        XCTAssertEqual(store2.address, store.address)
        XCTAssertEqual(store2.contact, store.contact)
        XCTAssertEqual(store2.defaultWeight, 2.5)
        XCTAssertEqual(store2.lastConfirmation?.confirmationNumber, "WTC1")
        XCTAssertEqual(store2.lastConfirmation?.pickupDate, "2026-09-19")
        XCTAssertTrue(store2.isAddressConfigured)
    }

    func testCorruptDataFallsBackToDefaults() {
        defaults.set(Data([0x00, 0x01, 0x02, 0xFF]), forKey: "settings.v1")

        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.defaultLocation, .frontDoor)
        XCTAssertNil(store.address)
        XCTAssertNil(store.contact)
    }

    func testPartialSnapshotKeepsDefaultsForMissingKeys() {
        // A snapshot written by another version of the app: one known key only.
        defaults.set(Data(#"{"defaultWeight": 2}"#.utf8), forKey: "settings.v1")

        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.defaultWeight, 2)
        XCTAssertEqual(store.defaultLocation, .frontDoor)
        XCTAssertEqual(store.defaultInstructions, "")
        XCTAssertFalse(store.dogPresent)
        XCTAssertFalse(store.useTestEnvironment)
        XCTAssertNil(store.address)
        XCTAssertNil(store.contact)
        XCTAssertNil(store.lastConfirmation)
    }

    func testUnknownFieldDoesNotWipeSavedAddress() throws {
        let store = SettingsStore(defaults: defaults)
        store.address = PostalAddress(streetAddress: "123 Main St", secondaryAddress: nil,
                                      city: "Springfield", state: "IL", ZIPCode: "62701",
                                      ZIPPlus4: nil)
        store.contact = PickupContact(firstName: "Todd", lastName: "Anglin", firm: nil,
                                      phone: "5551234567", email: nil)

        // Simulate a future version adding a field to the snapshot.
        let data = try XCTUnwrap(defaults.data(forKey: "settings.v1"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["someFutureField"] = ["nested": true]
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "settings.v1")

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.address, store.address)
        XCTAssertEqual(reloaded.contact, store.contact)
    }

    func testClearResets() {
        let store = SettingsStore(defaults: defaults)
        store.defaultLocation = .mailbox
        store.address = PostalAddress(streetAddress: "123 Main St", secondaryAddress: nil, city: "Springfield", state: "IL", ZIPCode: "62701", ZIPPlus4: nil)
        store.contact = PickupContact(firstName: "Todd", lastName: "Anglin", firm: nil, phone: "5551234567", email: nil)
        store.dogPresent = true
        store.defaultWeight = 5
        store.useTestEnvironment = true
        store.lastConfirmation = PickupConfirmation(confirmationNumber: "WTC1", pickupDate: "2026-09-19")

        store.clear()

        let store2 = SettingsStore(defaults: defaults)
        XCTAssertEqual(store2.defaultLocation, .frontDoor)
        XCTAssertEqual(store2.defaultWeight, 1)
        XCTAssertEqual(store2.defaultInstructions, "")
        XCTAssertFalse(store2.dogPresent)
        XCTAssertFalse(store2.useTestEnvironment)
        XCTAssertNil(store2.address)
        XCTAssertNil(store2.contact)
        XCTAssertNil(store2.lastConfirmation)
        XCTAssertFalse(store2.isAddressConfigured)
    }
}
