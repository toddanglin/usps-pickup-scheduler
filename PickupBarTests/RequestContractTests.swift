import XCTest
@testable import PickupBar

/// Checks the JSON PickupBar sends to `POST /pickup/v3/carrier-pickup` against
/// the USPS contract. The constants below are copied from
/// `components.schemas` in `docs/usps/carrier-pickup-v3.yaml` (Carrier Pickup
/// 3.1.10) — update them from that file, never from the README examples in
/// USPS/api-examples, which are stale (they show a `phone` contact key that
/// the live API rejects).
final class RequestContractTests: XCTestCase {

    // MARK: - Spec constants

    /// `SchedulePickupRequest` (additionalProperties: false).
    static let requestKeys: Set<String> = ["pickupDate", "pickupAddress", "packages", "estimatedWeight",
                                           "pickupLocation", "nextAvailablePickup"]
    static let requiredRequestKeys: Set<String> = ["pickupDate", "pickupAddress", "packages",
                                                   "estimatedWeight", "pickupLocation"]
    /// `PickupAddress` (additionalProperties: false) = `Addressee` + `address` + `contact`.
    static let pickupAddressKeys: Set<String> = ["firstName", "lastName", "firm", "address", "contact"]
    /// `DomesticAddress` + `Address` (writable fields).
    static let addressKeys: Set<String> = ["streetAddress", "secondaryAddress", "city", "state",
                                           "ZIPCode", "ZIPPlus4", "urbanization"]
    /// `NotificationMethod` oneOf `EmailNotification` / `SMSNotification`.
    static let contactKeys: Set<String> = ["email", "cellNumber"]
    /// `SchedulePickupRequest_packages` (additionalProperties: false).
    static let packageKeys: Set<String> = ["packageType", "packageCount"]
    static let packageTypes: Set<String> = ["FIRST-CLASS_PACKAGE_SERVICE", "PRIORITY_MAIL_EXPRESS",
                                            "PRIORITY_MAIL", "RETURNS", "USPS_GROUND_ADVANTAGE",
                                            "INTERNATIONAL", "OTHER"]
    /// `SchedulePickupRequest_pickupLocation` (additionalProperties: false).
    static let pickupLocationKeys: Set<String> = ["packageLocation", "specialInstructions", "dogPresent"]
    static let packageLocations: Set<String> = ["FRONT_DOOR", "BACK_DOOR", "SIDE_DOOR", "KNOCK_ON_DOOR",
                                                "MAIL_ROOM", "OFFICE", "PORCH", "RECEPTION", "MAILBOX",
                                                "OTHER"]

    // MARK: - Fixtures

    private let address = PostalAddress(streetAddress: "475 L'Enfant Plaza SW", secondaryAddress: nil,
                                        city: "Washington", state: "DC", ZIPCode: "20260", ZIPPlus4: nil)

    private func contact(phone: String = "", email: String? = nil) -> PickupContact {
        PickupContact(firstName: "Test", lastName: "User", firm: nil, phone: phone, email: email)
    }

    private func draft(location: PackageLocation = .frontDoor, instructions: String = "",
                       counts: [PackageType: Int] = [.priorityMail: 1]) -> PickupDraft {
        var all: [PackageType: Int] = [:]
        for type in PackageType.allCases { all[type] = counts[type] ?? 0 }
        return PickupDraft(selectedDate: Date(timeIntervalSince1970: 1_790_000_000), location: location,
                           instructions: instructions, dogPresent: false, counts: all, weight: 2,
                           hazmatConfirmed: true)
    }

    // MARK: - Tests

    func testEmailOnly() throws {
        let json = try assertContract(draft(), contact(email: "test@example.com"))
        XCTAssertEqual(contactEntries(json) as? [[String: String]], [["email": "test@example.com"]])
    }

    func testPhoneOnly() throws {
        let json = try assertContract(draft(), contact(phone: "2025550123"))
        XCTAssertEqual(contactEntries(json) as? [[String: String]], [["cellNumber": "2025550123"]])
    }

    func testEmailAndPhone() throws {
        let json = try assertContract(draft(), contact(phone: "2025550123", email: "test@example.com"))
        XCTAssertEqual(contactEntries(json) as? [[String: String]],
                       [["email": "test@example.com"], ["cellNumber": "2025550123"]])
    }

    func testLocationOtherCarriesInstructions() throws {
        let json = try assertContract(draft(location: .other, instructions: "Behind the garage"),
                                      contact(email: "test@example.com"))
        let location = try XCTUnwrap(json["pickupLocation"] as? [String: Any])
        XCTAssertEqual(location["packageLocation"] as? String, "OTHER")
        XCTAssertEqual(location["specialInstructions"] as? String, "Behind the garage")
    }

    func testEveryPackageType() throws {
        var counts: [PackageType: Int] = [:]
        for type in PackageType.allCases { counts[type] = 1 }
        let json = try assertContract(draft(counts: counts), contact(email: "test@example.com"))
        XCTAssertEqual((json["packages"] as? [Any])?.count, PackageType.allCases.count)
        for type in PackageType.allCases {
            XCTAssertTrue(Self.packageTypes.contains(type.rawValue), "\(type.rawValue) is not in the spec enum")
        }
    }

    func testEveryPackageLocation() throws {
        for location in PackageLocation.allCases {
            XCTAssertTrue(Self.packageLocations.contains(location.rawValue),
                          "\(location.rawValue) is not in the spec enum")
            try assertContract(draft(location: location, instructions: location == .other ? "Gate" : ""),
                               contact(phone: "2025550123"))
        }
    }

    // MARK: - Contract check

    private func contactEntries(_ json: [String: Any]) -> [Any]? {
        (json["pickupAddress"] as? [String: Any])?["contact"] as? [Any]
    }

    /// Encodes the draft's request exactly as `LiveUSPSClient` does and checks
    /// it against the spec. Returns the decoded JSON for further assertions.
    @discardableResult
    private func assertContract(_ draft: PickupDraft, _ contact: PickupContact,
                                file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let request = draft.request(address: address, contact: contact)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(request)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("null"), "no JSON null anywhere: \(text)", file: file, line: line)

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let keys = Set(json.keys)
        XCTAssertTrue(keys.isSubset(of: Self.requestKeys), "top-level keys \(keys)", file: file, line: line)
        XCTAssertTrue(Self.requiredRequestKeys.isSubset(of: keys), "missing required keys", file: file, line: line)

        let pickupAddress = try XCTUnwrap(json["pickupAddress"] as? [String: Any])
        XCTAssertTrue(Set(pickupAddress.keys).isSubset(of: Self.pickupAddressKeys),
                      "pickupAddress keys \(pickupAddress.keys)", file: file, line: line)
        for name in ["firstName", "lastName"] {
            let value = try XCTUnwrap(pickupAddress[name] as? String)
            XCTAssertTrue((1...50).contains(value.count), file: file, line: line)
        }
        let address = try XCTUnwrap(pickupAddress["address"] as? [String: Any])
        XCTAssertTrue(Set(address.keys).isSubset(of: Self.addressKeys), "address keys \(address.keys)",
                      file: file, line: line)
        XCTAssertNotNil((address["ZIPCode"] as? String)?.range(of: #"^\d{5}$"#, options: .regularExpression),
                        file: file, line: line)

        let contact = try XCTUnwrap(pickupAddress["contact"] as? [[String: Any]])
        XCTAssertTrue((1...2).contains(contact.count), "contact count \(contact.count)", file: file, line: line)
        for entry in contact {
            XCTAssertEqual(entry.count, 1, "each contact entry has exactly one key: \(entry)", file: file, line: line)
            XCTAssertTrue(Set(entry.keys).isSubset(of: Self.contactKeys), "contact keys \(entry.keys)",
                          file: file, line: line)
            if let cell = entry["cellNumber"] {
                XCTAssertNotNil((cell as? String)?.range(of: #"^\d{10}$"#, options: .regularExpression),
                                file: file, line: line)
            }
            if let email = entry["email"] as? String {
                XCTAssertLessThanOrEqual(email.count, 50, file: file, line: line)
            }
        }

        let packages = try XCTUnwrap(json["packages"] as? [[String: Any]])
        XCTAssertFalse(packages.isEmpty, file: file, line: line)
        for package in packages {
            XCTAssertEqual(Set(package.keys), Self.packageKeys, file: file, line: line)
            XCTAssertTrue(Self.packageTypes.contains(package["packageType"] as? String ?? ""),
                          "packageType \(package["packageType"] ?? "")", file: file, line: line)
            XCTAssertTrue(package["packageCount"] is Int, file: file, line: line)
        }

        let location = try XCTUnwrap(json["pickupLocation"] as? [String: Any])
        XCTAssertTrue(Set(location.keys).isSubset(of: Self.pickupLocationKeys), "pickupLocation keys \(location.keys)",
                      file: file, line: line)
        let packageLocation = location["packageLocation"] as? String ?? ""
        XCTAssertTrue(Self.packageLocations.contains(packageLocation), "packageLocation \(packageLocation)",
                      file: file, line: line)
        if packageLocation == "OTHER" {
            let instructions = (location["specialInstructions"] as? String ?? "")
                .trimmingCharacters(in: .whitespaces)
            XCTAssertFalse(instructions.isEmpty, "OTHER needs specialInstructions", file: file, line: line)
        }
        XCTAssertNotNil(json["estimatedWeight"] as? Double, file: file, line: line)
        XCTAssertNotNil((json["pickupDate"] as? String)?.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression),
                        file: file, line: line)
        return json
    }
}
