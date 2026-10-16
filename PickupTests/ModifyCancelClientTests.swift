import XCTest
@testable import Pickup

/// GET / PUT / DELETE `/pickup/v3/carrier-pickup/{confirmationNumber}`, built
/// to what apis-tem.usps.com actually returned (see the design spec, §4.7).
final class ModifyCancelClientTests: XCTestCase {
    let baseURL = URL(string: "https://apis-tem.usps.com")!
    var client: LiveUSPSClient!

    override func setUp() {
        super.setUp()
        client = LiveUSPSClient(baseURL: baseURL, session: MockURLProtocol.session())
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        client = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// The body USPS TEM returned for GET (and PUT), contact quirks included.
    static let fetchedJSON = """
    {"confirmationNumber":"EMC123456789","pickupDate":"2026-10-16",
     "carrierPickupRequest":{"pickupDate":"2026-10-16",
      "pickupAddress":{"firstName":"TODD","lastName":"ANGLIN",
        "address":{"streetAddress":"1600 PENNSYLVANIA AVE NW","city":"WASHINGTON","state":"DC",
                   "ZIPCode":"20500","ZIPPlus4":"0005"},
        "contact":[{},{"cellNumber":"2025550123"}]},
      "packages":[{"packageType":"PRIORITY_MAIL_EXPRESS","packageCount":0},
                  {"packageType":"PRIORITY_MAIL","packageCount":2},
                  {"packageType":"RETURNS","packageCount":0},
                  {"packageType":"USPS_GROUND_ADVANTAGE","packageCount":3},
                  {"packageType":"INTERNATIONAL","packageCount":0},
                  {"packageType":"OTHER","packageCount":0}],
      "estimatedWeight":3,
      "pickupLocation":{"packageLocation":"PORCH","dogPresent":false}}}
    """

    static let staleETagJSON = """
    {"error":{"message":"The resource, /pickup/v3/carrier-pickup/EMC123456789 has been modified since the update indicated by the If-Match request header.","errors":[]}}
    """

    static let alreadyCancelledJSON = """
    {"error":{"code":"400","message":"Pickup already cancelled.","errors":[{"title":"Pickup already cancelled.","detail":"Pickup already cancelled.","code":"1401"}]}}
    """

    static let pastDateJSON = """
    {"error":{"message":"Pickup date is in the past.","errors":[{"code":"1100","detail":"Pickup date is in the past."}]}}
    """

    private func respond(_ status: Int, _ body: String, headers: [String: String] = [:],
                         capture: (@Sendable (URLRequest) -> Void)? = nil) {
        MockURLProtocol.handler = { request in
            capture?(request)
            var fields = ["Content-Type": "application/json"]
            for (key, value) in headers { fields[key] = value }
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/2", headerFields: fields)!
            return (response, Data(body.utf8))
        }
    }

    private func sampleRequest() -> SchedulePickupRequest {
        SchedulePickupRequest(
            pickupDate: "2026-10-19",
            pickupAddress: PickupAddress(
                contact: PickupContact(firstName: "Todd", lastName: "Anglin", firm: nil,
                                       phone: "2025550123", email: nil),
                address: PostalAddress(streetAddress: "1600 Pennsylvania Ave NW", secondaryAddress: nil,
                                       city: "Washington", state: "DC", ZIPCode: "20500", ZIPPlus4: nil)),
            packages: [PackageLine(packageType: .groundAdvantage, packageCount: 3)],
            estimatedWeight: 4,
            pickupLocation: PickupLocation(packageLocation: .porch, specialInstructions: nil,
                                           dogPresent: false),
            nextAvailablePickup: true)
    }

    private func assertUSPSError(_ expected: USPSError, _ body: @autoclosure () async throws -> Any,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected) but call succeeded", file: file, line: line)
        } catch let error as USPSError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected USPSError but got \(error)", file: file, line: line)
        }
    }

    // MARK: - GET

    func testFetchPickupRequestShape() async throws {
        let captured = CapturedRequest()
        respond(200, Self.fetchedJSON, headers: ["etag": "abc+/=="]) { captured.value = $0 }

        _ = try await client.fetchPickup(confirmationNumber: "EMC123456789", token: "tok")

        let request = try XCTUnwrap(captured.value)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString,
                       "https://apis-tem.usps.com/pickup/v3/carrier-pickup/EMC123456789")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "If-Match"))
    }

    func testFetchPickupReadsLowerCaseETagAndTheRealBody() async throws {
        respond(200, Self.fetchedJSON, headers: ["etag": "eyJ2ZXJzaW9uIjoxfQ=="])

        let fetched = try await client.fetchPickup(confirmationNumber: "EMC123456789", token: "tok")

        XCTAssertEqual(fetched.etag, "eyJ2ZXJzaW9uIjoxfQ==")
        XCTAssertEqual(fetched.confirmation,
                       PickupConfirmation(confirmationNumber: "EMC123456789", pickupDate: "2026-10-16"))
        let request = try XCTUnwrap(fetched.request)
        XCTAssertEqual(request.pickupDate, "2026-10-16")
        XCTAssertEqual(request.estimatedWeight, 3)
        XCTAssertEqual(request.pickupLocation,
                       PickupLocation(packageLocation: .porch, specialInstructions: nil, dogPresent: false))
        XCTAssertEqual(request.packages.count, 6, "zero-count lines are kept as USPS sent them")
        XCTAssertEqual(request.packages.first { $0.packageType == .groundAdvantage }?.packageCount, 3)
        XCTAssertEqual(request.packages.first { $0.packageType == .priorityMail }?.packageCount, 2)
        XCTAssertFalse(request.nextAvailablePickup)
        // `{}` is dropped; the real cell number survives.
        XCTAssertEqual(request.pickupAddress.contact, [.cellNumber("2025550123")])
        XCTAssertEqual(request.pickupAddress.firstName, "TODD")
        XCTAssertEqual(request.pickupAddress.address.ZIPPlus4, "0005")
    }

    func testFetchPickupReadsUpperCaseETag() async throws {
        respond(200, Self.fetchedJSON, headers: ["ETag": "UPPER"])
        let fetched = try await client.fetchPickup(confirmationNumber: "EMC123456789", token: "tok")
        XCTAssertEqual(fetched.etag, "UPPER")
    }

    func testFetchPickupStripsJunkContactEntries() async throws {
        let json = Self.fetchedJSON.replacingOccurrences(
            of: #"[{},{"cellNumber":"2025550123"}]"#,
            with: #"[{"cellNumber":"nullnullnull"},{"email":"TODD@EXAMPLE.COM"}]"#)
        respond(200, json, headers: ["etag": "e"])
        let fetched = try await client.fetchPickup(confirmationNumber: "EMC123456789", token: "tok")
        XCTAssertEqual(fetched.request?.pickupAddress.contact, [.email("TODD@EXAMPLE.COM")])
    }

    func testFetchPickupUndecodableRequestStillReturnsTheConfirmation() async throws {
        respond(200, #"{"confirmationNumber":"EMC1","pickupDate":"2026-10-16","carrierPickupRequest":{"packages":"nope"}}"#,
                headers: ["etag": "e"])
        let fetched = try await client.fetchPickup(confirmationNumber: "EMC1", token: "tok")
        XCTAssertEqual(fetched.confirmation.pickupDate, "2026-10-16")
        XCTAssertNil(fetched.request)
        XCTAssertEqual(fetched.etag, "e")
    }

    func testFetchPickupWithoutETagFails() async {
        respond(200, Self.fetchedJSON)
        do {
            _ = try await client.fetchPickup(confirmationNumber: "EMC123456789", token: "tok")
            XCTFail("expected a failure without an ETag")
        } catch let error as USPSError {
            guard case .unexpected(let status, _) = error else { return XCTFail("got \(error)") }
            XCTAssertEqual(status, 200)
        } catch {
            XCTFail("got \(error)")
        }
    }

    func testFetchPickup404IsNotFound() async {
        respond(404, #"{"error":{"code":"404","message":"Not Found"}}"#)
        await assertUSPSError(.notFound(message: "USPS doesn't know this confirmation number."),
                              try await client.fetchPickup(confirmationNumber: "NOPE", token: "tok"))
    }

    func testFetchPickup401IsInvalidCredentials() async {
        respond(401, #"{"error":{"code":"401","message":"Unauthorized"}}"#)
        await assertUSPSError(.invalidCredentials,
                              try await client.fetchPickup(confirmationNumber: "EMC1", token: "tok"))
    }

    // MARK: - PUT

    func testUpdatePickupSendsIfMatchAndTheRealBodyShape() async throws {
        let captured = CapturedRequest()
        respond(200, Self.fetchedJSON, headers: ["etag": "new-etag"]) { captured.value = $0 }

        let updated = try await client.updatePickup(confirmationNumber: "EMC123456789", etag: "old-etag",
                                                    request: sampleRequest(), token: "tok")

        XCTAssertEqual(updated.etag, "new-etag")
        XCTAssertEqual(updated.confirmation.pickupDate, "2026-10-16")

        let request = try XCTUnwrap(captured.value)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/pickup/v3/carrier-pickup/EMC123456789")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "old-etag")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")

        let body = try XCTUnwrap(request.bodyData)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["pickupDate", "carrierPickupRequest"])
        XCTAssertEqual(json["pickupDate"] as? String, "2026-10-19")
        let inner = try XCTUnwrap(json["carrierPickupRequest"] as? [String: Any])
        XCTAssertEqual(Set(inner.keys),
                       ["pickupDate", "pickupAddress", "packages", "estimatedWeight", "pickupLocation"],
                       "PUT must not carry nextAvailablePickup")
        XCTAssertEqual(inner["pickupDate"] as? String, "2026-10-19")
        XCTAssertEqual(inner["estimatedWeight"] as? Double, 4)
        let address = try XCTUnwrap(inner["pickupAddress"] as? [String: Any])
        XCTAssertEqual(address["contact"] as? [[String: String]], [["cellNumber": "2025550123"]])
    }

    func testUpdatePickupStaleETagIsRetryableBadRequest() async throws {
        respond(400, Self.staleETagJSON)
        do {
            _ = try await client.updatePickup(confirmationNumber: "EMC123456789", etag: "stale",
                                              request: sampleRequest(), token: "tok")
            XCTFail("expected failure")
        } catch let error as USPSError {
            guard case .badRequest(let message, _) = error else { return XCTFail("got \(error)") }
            XCTAssertTrue(message.contains("has been modified since"), message)
            XCTAssertTrue(error.isStaleETag)
            XCTAssertTrue(error.isRetryable)
            XCTAssertEqual(error.hint, "The pickup changed on USPS's side. Try again.")
        }
    }

    func testUpdatePickup404IsNotFound() async {
        respond(404, "")
        await assertUSPSError(.notFound(message: "USPS doesn't know this confirmation number."),
                              try await client.updatePickup(confirmationNumber: "NOPE", etag: "e",
                                                            request: sampleRequest(), token: "tok"))
    }

    // MARK: - DELETE

    func testCancelPickupSendsIfMatchAndAcceptsAnEmptyBody() async throws {
        let captured = CapturedRequest()
        respond(200, "") { captured.value = $0 }

        try await client.cancelPickup(confirmationNumber: "EMC123456789", etag: "the-etag", token: "tok")

        let request = try XCTUnwrap(captured.value)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/pickup/v3/carrier-pickup/EMC123456789")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "the-etag")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertNil(request.bodyData.flatMap { $0.isEmpty ? nil : $0 })
    }

    func testCancelPickupAlreadyCancelled() async {
        respond(400, Self.alreadyCancelledJSON)
        do {
            try await client.cancelPickup(confirmationNumber: "EMC123456789", etag: "e", token: "tok")
            XCTFail("expected failure")
        } catch let error as USPSError {
            guard case .badRequest(let message, _) = error else { return XCTFail("got \(error)") }
            XCTAssertEqual(message, "Pickup already cancelled.")
            XCTAssertTrue(error.isAlreadyCancelled)
            XCTAssertFalse(error.isRetryable)
            XCTAssertEqual(error.hint, "It's already cancelled with USPS — you can remove it from the list.")
        } catch {
            XCTFail("got \(error)")
        }
    }

    func testCancelPickupPastDate() async {
        respond(400, Self.pastDateJSON)
        do {
            try await client.cancelPickup(confirmationNumber: "EMC123456789", etag: "e", token: "tok")
            XCTFail("expected failure")
        } catch let error as USPSError {
            guard case .badRequest(let message, _) = error else { return XCTFail("got \(error)") }
            XCTAssertEqual(message, "Pickup date is in the past.")
            XCTAssertFalse(error.isAlreadyCancelled)
            XCTAssertFalse(error.isRetryable)
        } catch {
            XCTFail("got \(error)")
        }
    }

    func testCancelPickup404IsNotFound() async {
        respond(404, "")
        await assertUSPSError(.notFound(message: "USPS doesn't know this confirmation number."),
                              try await client.cancelPickup(confirmationNumber: "NOPE", etag: "e", token: "tok"))
    }

    // MARK: - Error copy

    func testNotFoundCopy() {
        let error = USPSError.notFound(message: "USPS doesn't know this confirmation number.")
        XCTAssertEqual(error.message, "USPS doesn't know this confirmation number.")
        XCTAssertFalse(error.isRetryable)
        XCTAssertNotNil(error.hint)
        XCTAssertTrue(error.technicalDetails.contains("notFound"))
    }
}
