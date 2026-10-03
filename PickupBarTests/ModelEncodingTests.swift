import XCTest
@testable import PickupBar

final class ModelEncodingTests: XCTestCase {
    private let plainAddress = PostalAddress(streetAddress: "1 Main St", secondaryAddress: nil, city: "Austin",
                                             state: "TX", ZIPCode: "78701", ZIPPlus4: nil)

    func testScheduleRequestEncodesUSPSShape() throws {
        let req = SchedulePickupRequest(
            pickupDate: "2026-09-19",
            pickupAddress: PickupAddress(
                firstName: "Todd", lastName: "Anglin", firm: nil,
                address: plainAddress,
                contact: [.email("t@example.com"), .cellNumber("5125551234")]),
            packages: [PackageLine(packageType: .priorityMail, packageCount: 2)],
            estimatedWeight: 3.5,
            pickupLocation: PickupLocation(packageLocation: .frontDoor, specialInstructions: "Behind planter", dogPresent: false),
            nextAvailablePickup: true)
        let data = try JSONEncoder().encode(req)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["pickupDate"] as? String, "2026-09-19")
        let addr = try XCTUnwrap(json["pickupAddress"] as? [String: Any])
        let contact = try XCTUnwrap(addr["contact"] as? [[String: Any]])
        XCTAssertEqual(contact.count, 2)
        XCTAssertEqual(contact[0] as? [String: String], ["email": "t@example.com"])
        XCTAssertEqual(contact[1] as? [String: String], ["cellNumber": "5125551234"])
        let pk = try XCTUnwrap(json["packages"] as? [[String: Any]])
        XCTAssertEqual(pk[0]["packageType"] as? String, "PRIORITY_MAIL")
        XCTAssertEqual(pk[0]["packageCount"] as? Int, 2)
        XCTAssertEqual((json["pickupLocation"] as? [String: Any])?["packageLocation"] as? String, "FRONT_DOOR")
        XCTAssertEqual(json["nextAvailablePickup"] as? Bool, true)
    }

    func testRequestWithEveryOptionalUnsetContainsNoNull() throws {
        let req = SchedulePickupRequest(
            pickupDate: "2026-09-19",
            pickupAddress: PickupAddress(
                firstName: "Todd", lastName: "Anglin", firm: nil,
                address: plainAddress,
                contact: [.email(nil), .cellNumber(nil)]),
            packages: [PackageLine(packageType: .priorityMail, packageCount: 1)],
            estimatedWeight: 1,
            pickupLocation: PickupLocation(packageLocation: .frontDoor, specialInstructions: nil, dogPresent: false),
            nextAvailablePickup: true)
        let text = String(decoding: try JSONEncoder().encode(req), as: UTF8.self)
        XCTAssertFalse(text.contains("null"), text)
        for key in ["firm", "secondaryAddress", "ZIPPlus4", "specialInstructions", "email", "cellNumber"] {
            XCTAssertFalse(text.contains("\"\(key)\""), "\(key) should be omitted: \(text)")
        }
    }

    func testEmptyStringOptionalsAreOmitted() throws {
        let req = SchedulePickupRequest(
            pickupDate: "2026-09-19",
            pickupAddress: PickupAddress(
                firstName: "Todd", lastName: "Anglin", firm: "",
                address: PostalAddress(streetAddress: "1 Main St", secondaryAddress: "", city: "Austin",
                                       state: "TX", ZIPCode: "78701", ZIPPlus4: ""),
                contact: [.email(""), .cellNumber("")]),
            packages: [PackageLine(packageType: .priorityMail, packageCount: 1)],
            estimatedWeight: 1,
            pickupLocation: PickupLocation(packageLocation: .frontDoor, specialInstructions: "", dogPresent: false),
            nextAvailablePickup: true)
        let text = String(decoding: try JSONEncoder().encode(req), as: UTF8.self)
        for key in ["firm", "secondaryAddress", "ZIPPlus4", "specialInstructions", "email", "cellNumber"] {
            XCTAssertFalse(text.contains("\"\(key)\""), "\(key) should be omitted: \(text)")
        }
    }

    func testPackageCountDecodesFromString() throws {
        let line = try JSONDecoder().decode(PackageLine.self, from: Data(#"{"packageType":"OTHER","packageCount":"3"}"#.utf8))
        XCTAssertEqual(line.packageCount, 3)
    }

    func testConfirmationDecodesFlatAndNestedShapes() throws {
        let flat = try JSONDecoder().decode(PickupConfirmation.self, from: Data(#"{"confirmationNumber":"WTC123","pickupDate":"2026-09-19","estimatedWeight":"5"}"#.utf8))
        XCTAssertEqual(flat.confirmationNumber, "WTC123")
        let nested = try JSONDecoder().decode(PickupConfirmation.self, from: Data(#"{"confirmationNumber":"WTC124","pickupDate":"2026-09-20","carrierPickupRequest":{"pickupDate":"2026-09-20"}}"#.utf8))
        XCTAssertEqual(nested.pickupDate, "2026-09-20")
    }

    // MARK: - ContactEntry

    func testContactEntryDecodesEveryKnownSpelling() throws {
        let entries = try JSONDecoder().decode([ContactEntry].self, from: Data(#"""
        [{"eMail":null},{"phone":"3333333333","extension":null},
         {"email":"a@b.co"},{"cellNumber":"4444444444"},{}]
        """#.utf8))
        XCTAssertEqual(entries, [.email(nil), .cellNumber("3333333333"),
                                 .email("a@b.co"), .cellNumber("4444444444"), .email(nil)])
    }

    func testPickupAddressFromContactWithEmailOnly() {
        let c = PickupContact(firstName: "A", lastName: "B", firm: nil, phone: "", email: "a@b.co")
        XCTAssertEqual(PickupAddress(contact: c, address: plainAddress).contact, [.email("a@b.co")])
    }

    func testPickupAddressFromContactWithPhoneOnly() {
        let c = PickupContact(firstName: "A", lastName: "B", firm: nil, phone: "5125551234", email: nil)
        XCTAssertEqual(PickupAddress(contact: c, address: plainAddress).contact, [.cellNumber("5125551234")])
    }

    func testPickupAddressFromContactWithBoth() {
        let c = PickupContact(firstName: "A", lastName: "B", firm: nil, phone: "(512) 555-1234", email: "a@b.co")
        XCTAssertEqual(PickupAddress(contact: c, address: plainAddress).contact,
                       [.email("a@b.co"), .cellNumber("5125551234")])
    }

    func testPickupAddressDropsAPhoneThatIsNotTenDigitsWhenThereIsAnEmail() {
        let c = PickupContact(firstName: "A", lastName: "B", firm: "", phone: "555123", email: "a@b.co")
        let address = PickupAddress(contact: c, address: plainAddress)
        XCTAssertEqual(address.contact, [.email("a@b.co")])
        XCTAssertNil(address.firm, "an empty firm is not sent")
    }

    func testPickupContactWithoutAPhoneKeyStillDecodes() throws {
        let contact = try JSONDecoder().decode(PickupContact.self, from: Data(#"{"firstName":"A","lastName":"B","email":"a@b.co"}"#.utf8))
        XCTAssertEqual(contact.phone, "")
        XCTAssertEqual(contact.email, "a@b.co")
    }

    // MARK: - Enums

    func testPackageTypeRawValuesMatchTheSpec() {
        XCTAssertEqual(PackageType.groundAdvantage.rawValue, "USPS_GROUND_ADVANTAGE")
        XCTAssertEqual(PackageType.allCases, [.groundAdvantage, .priorityMail, .priorityMailExpress,
                                              .international, .returns, .other])
    }

    func testPackageTypeDecodesLeniently() throws {
        let types = try JSONDecoder().decode([PackageType].self, from: Data(#"["USPS_GROUND_ADVANTAGE","FIRST-CLASS_PACKAGE_SERVICE","SOMETHING_NEW"]"#.utf8))
        XCTAssertEqual(types, [.groundAdvantage, .groundAdvantage, .other])
    }

    func testPackageLocationCasesMatchTheSpec() {
        XCTAssertEqual(PackageLocation.allCases.map(\.rawValue),
                       ["FRONT_DOOR", "BACK_DOOR", "SIDE_DOOR", "KNOCK_ON_DOOR", "MAIL_ROOM",
                        "OFFICE", "PORCH", "RECEPTION", "MAILBOX", "OTHER"])
        XCTAssertEqual(PackageLocation.allCases.map(\.displayName),
                       ["Front Door", "Back Door", "Side Door", "Knock on Door / Ring Bell", "Mail Room",
                        "Office", "Porch", "Reception", "Mailbox", "Other"])
    }

    func testPackageLocationDecodesLegacyValues() throws {
        let locations = try JSONDecoder().decode([PackageLocation].self, from: Data(#"["IN_AT_MAILBOX","SECURITY_DECK","SHIPPING_DOCK","PORCH"]"#.utf8))
        XCTAssertEqual(locations, [.mailbox, .other, .other, .porch])
    }

    func testDisplayNames() {
        XCTAssertEqual(PackageType.groundAdvantage.displayName, "Ground Advantage")
        XCTAssertEqual(PackageLocation.knockOnDoor.displayName, "Knock on Door / Ring Bell")
    }
}
