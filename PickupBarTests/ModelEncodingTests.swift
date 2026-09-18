import XCTest
@testable import PickupBar

final class ModelEncodingTests: XCTestCase {
    func testScheduleRequestEncodesUSPSShape() throws {
        let req = SchedulePickupRequest(
            pickupDate: "2026-09-19",
            pickupAddress: PickupAddress(
                firstName: "Todd", lastName: "Anglin", firm: nil,
                address: PostalAddress(streetAddress: "1 Main St", secondaryAddress: nil, city: "Austin", state: "TX", ZIPCode: "78701", ZIPPlus4: nil),
                contact: [.email("t@example.com"), .phone("5125551234")]),
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
        XCTAssertEqual(contact[0]["email"] as? String, "t@example.com")
        XCTAssertEqual(contact[1]["phone"] as? String, "5125551234")
        let pk = try XCTUnwrap(json["packages"] as? [[String: Any]])
        XCTAssertEqual(pk[0]["packageType"] as? String, "PRIORITY_MAIL")
        XCTAssertEqual(pk[0]["packageCount"] as? Int, 2)
        XCTAssertEqual((json["pickupLocation"] as? [String: Any])?["packageLocation"] as? String, "FRONT_DOOR")
        XCTAssertEqual(json["nextAvailablePickup"] as? Bool, true)
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

    func testContactEntryDecodes() throws {
        let entries = try JSONDecoder().decode([ContactEntry].self, from: Data(#"[{"eMail":null},{"phone":"3333333333","extension":null}]"#.utf8))
        XCTAssertEqual(entries, [.email(nil), .phone("3333333333")])
    }

    func testPickupAddressConvenienceInitOmitsEmptyEmail() {
        let c = PickupContact(firstName: "A", lastName: "B", firm: nil, phone: "5125551234", email: nil)
        let a = PostalAddress(streetAddress: "1 Main St", secondaryAddress: nil, city: "Austin", state: "TX", ZIPCode: "78701", ZIPPlus4: nil)
        XCTAssertEqual(PickupAddress(contact: c, address: a).contact, [.phone("5125551234")])
    }

    func testDisplayNames() {
        XCTAssertEqual(PackageType.groundAdvantage.displayName, "Ground Advantage")
        XCTAssertEqual(PackageLocation.knockOnDoor.displayName, "Knock on Door / Ring Bell")
    }
}
