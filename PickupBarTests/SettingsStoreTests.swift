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

    func testLegacyMailboxDefaultLocationMigrates() {
        defaults.set(Data(#"{"defaultLocation": "IN_AT_MAILBOX"}"#.utf8), forKey: "settings.v1")
        XCTAssertEqual(SettingsStore(defaults: defaults).defaultLocation, .mailbox)
    }

    func testUnknownDefaultLocationFallsBackToFrontDoor() {
        defaults.set(Data(#"{"defaultLocation": "SECURITY_DECK", "defaultWeight": 3}"#.utf8),
                     forKey: "settings.v1")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.defaultLocation, .frontDoor)
        XCTAssertEqual(store.defaultWeight, 3, "the rest of the snapshot still loads")
    }

    func testLegacyPhoneOnlyContactStillProducesAValidRequest() throws {
        // Written by v1.0: a phone, no email.
        defaults.set(Data(#"""
        {"contact": {"firstName": "Todd", "lastName": "Anglin", "phone": "5551234567"},
         "address": {"streetAddress": "123 Main St", "city": "Springfield", "state": "IL", "ZIPCode": "62701"},
         "defaultLocation": "SHIPPING_DOCK"}
        """#.utf8), forKey: "settings.v1")
        let store = SettingsStore(defaults: defaults)
        let contact = try XCTUnwrap(store.contact)
        let address = try XCTUnwrap(store.address)
        XCTAssertEqual(contact.phone, "5551234567")
        XCTAssertNil(contact.email)

        let wire = PickupAddress(contact: contact, address: address)
        XCTAssertEqual(wire.contact, [.cellNumber("5551234567")])
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

    // MARK: - History

    private func record(_ number: String, date: String = "2026-10-03") -> PickupRecord {
        PickupRecord(confirmationNumber: number, pickupDate: date, createdAt: Date(timeIntervalSince1970: 0),
                     packages: [PackageLine(packageType: .priorityMail, packageCount: 2)],
                     estimatedWeight: 3, location: .porch, addressLine: "1 MAIN ST, SPRINGFIELD IL")
    }

    func testHistoryStartsEmpty() {
        XCTAssertEqual(SettingsStore(defaults: defaults).history, [])
    }

    func testHistoryPersistsNewestFirst() {
        let store = SettingsStore(defaults: defaults)
        store.addToHistory(record("WTC1"))
        store.addToHistory(record("WTC2"))

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.history.map(\.confirmationNumber), ["WTC2", "WTC1"])
        XCTAssertEqual(reloaded.history.first, record("WTC2"))
    }

    func testHistoryDedupesByConfirmationNumber() {
        let store = SettingsStore(defaults: defaults)
        store.addToHistory(record("WTC1", date: "2026-10-03"))
        store.addToHistory(record("WTC2"))
        store.addToHistory(record("WTC1", date: "2026-10-05"))

        XCTAssertEqual(store.history.map(\.confirmationNumber), ["WTC1", "WTC2"])
        XCTAssertEqual(store.history.first?.pickupDate, "2026-10-05")
    }

    func testHistoryIsCapped() {
        let store = SettingsStore(defaults: defaults)
        for i in 0..<(SettingsStore.historyLimit + 5) {
            store.addToHistory(record("WTC\(i)"))
        }
        XCTAssertEqual(store.history.count, SettingsStore.historyLimit)
        XCTAssertEqual(store.history.first?.confirmationNumber, "WTC\(SettingsStore.historyLimit + 4)")
        // The oldest five fell off.
        XCTAssertFalse(store.history.contains { $0.confirmationNumber == "WTC4" })
        XCTAssertTrue(store.history.contains { $0.confirmationNumber == "WTC5" })
        XCTAssertEqual(SettingsStore(defaults: defaults).history.count, SettingsStore.historyLimit)
    }

    func testRemoveFromHistory() {
        let store = SettingsStore(defaults: defaults)
        store.addToHistory(record("WTC1"))
        store.addToHistory(record("WTC2"))
        store.removeFromHistory(confirmationNumber: "WTC1")
        XCTAssertEqual(store.history.map(\.confirmationNumber), ["WTC2"])
        XCTAssertEqual(SettingsStore(defaults: defaults).history.map(\.confirmationNumber), ["WTC2"])
    }

    func testOldSnapshotWithLastConfirmationSeedsHistory() throws {
        // Written by a version without `history`.
        let json = #"""
        {"defaultLocation":"PORCH","defaultInstructions":"","dogPresent":false,"defaultWeight":1,
         "useTestEnvironment":false,
         "address":{"streetAddress":"43 S SPRING TRELLIS CIR","city":"THE WOODLANDS","state":"TX","ZIPCode":"77382"},
         "contact":{"firstName":"Todd","lastName":"Anglin","phone":"5551234567"},
         "lastConfirmation":{"confirmationNumber":"WTC999","pickupDate":"2026-10-03"}}
        """#
        defaults.set(Data(json.utf8), forKey: "settings.v1")

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.address?.city, "THE WOODLANDS")
        XCTAssertEqual(store.defaultLocation, .porch)
        let seeded = try XCTUnwrap(store.history.first)
        XCTAssertEqual(store.history.count, 1)
        XCTAssertEqual(seeded.confirmationNumber, "WTC999")
        XCTAssertEqual(seeded.pickupDate, "2026-10-03")
        XCTAssertEqual(seeded.packages, [])
        XCTAssertEqual(seeded.totalPackages, 0)
        XCTAssertEqual(seeded.estimatedWeight, 0)
        XCTAssertEqual(seeded.location, .frontDoor)
        XCTAssertEqual(seeded.addressLine, "43 S SPRING TRELLIS CIR, THE WOODLANDS TX")

        // The seeded record is persisted, and not seeded twice.
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.history.map(\.confirmationNumber), ["WTC999"])
    }

    func testOldSnapshotWithoutHistoryOrConfirmationDecodes() {
        defaults.set(Data(#"{"defaultWeight": 4, "dogPresent": true}"#.utf8), forKey: "settings.v1")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.defaultWeight, 4)
        XCTAssertTrue(store.dogPresent)
        XCTAssertEqual(store.history, [])
    }

    func testMigrationDoesNotRunWhenHistoryExists() {
        let store = SettingsStore(defaults: defaults)
        store.addToHistory(record("WTC1"))
        store.lastConfirmation = PickupConfirmation(confirmationNumber: "WTC1", pickupDate: "2026-10-03")
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.history, [record("WTC1")])
    }

    func testClearEmptiesHistory() {
        let store = SettingsStore(defaults: defaults)
        store.addToHistory(record("WTC1"))
        store.clear()
        XCTAssertEqual(store.history, [])
        XCTAssertEqual(SettingsStore(defaults: defaults).history, [])
    }
}
