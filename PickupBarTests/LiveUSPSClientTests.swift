import XCTest
@testable import PickupBar

final class LiveUSPSClientTests: XCTestCase {
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

    // MARK: - Helpers

    private func respond(_ status: Int, _ json: String,
                         capture: (@Sendable (URLRequest) -> Void)? = nil) {
        MockURLProtocol.handler = { request in
            capture?(request)
            return (MockURLProtocol.response(request, status), Data(json.utf8))
        }
    }

    private func sampleAddress(secondary: String? = nil, zipPlus4: String? = nil) -> PostalAddress {
        PostalAddress(streetAddress: "4120 Bingham Ave", secondaryAddress: secondary,
                      city: "Saint Louis", state: "MO", ZIPCode: "63116", ZIPPlus4: zipPlus4)
    }

    private func sampleRequest() -> SchedulePickupRequest {
        SchedulePickupRequest(
            pickupDate: "2026-09-21",
            pickupAddress: PickupAddress(
                contact: PickupContact(firstName: "Todd", lastName: "Anglin", firm: nil,
                                       phone: "3145551212", email: "todd@example.com"),
                address: sampleAddress()),
            packages: [PackageLine(packageType: .priorityMail, packageCount: 2)],
            estimatedWeight: 3.5,
            pickupLocation: PickupLocation(packageLocation: .frontDoor,
                                           specialInstructions: "By the planter",
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

    // MARK: - Token

    func testFetchTokenRequestShapeAndNumericExpiry() async throws {
        let captured = CapturedRequest()
        respond(200, #"{"access_token":"tok-123","token_type":"Bearer","issued_at":1680888985929,"expires_in":28799}"#) {
            captured.value = $0
        }

        let before = Date()
        let token = try await client.fetchToken(clientID: "key", clientSecret: "secret")

        XCTAssertEqual(token.accessToken, "tok-123")
        let expected = before.addingTimeInterval(28_799)
        XCTAssertEqual(token.expiresAt.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 2)

        let request = try XCTUnwrap(captured.value)
        XCTAssertEqual(request.url?.absoluteString, "https://apis-tem.usps.com/oauth2/v3/token")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.bodyData)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["grant_type": "client_credentials",
                              "client_id": "key",
                              "client_secret": "secret"])
    }

    func testFetchTokenAcceptsStringExpiresIn() async throws {
        respond(200, #"{"access_token":"tok","token_type":"Bearer","issued_at":"1680888985929","expires_in":"3600"}"#)
        let before = Date()
        let token = try await client.fetchToken(clientID: "k", clientSecret: "s")
        XCTAssertEqual(token.accessToken, "tok")
        XCTAssertEqual(token.expiresAt.timeIntervalSince1970,
                       before.addingTimeInterval(3600).timeIntervalSince1970, accuracy: 2)
    }

    func testFetchTokenParsesScopesAndAPIProducts() async throws {
        respond(200, #"{"access_token":"tok","expires_in":28799,"scope":"domestic-prices addresses locations","api_products":"[Default Access]"}"#)
        let token = try await client.fetchToken(clientID: "k", clientSecret: "s")
        XCTAssertEqual(token.scopes, ["domestic-prices", "addresses", "locations"])
        XCTAssertEqual(token.apiProducts, "[Default Access]")
    }

    func testFetchTokenWithoutScopeHasNoScopes() async throws {
        respond(200, #"{"access_token":"tok","expires_in":28799}"#)
        let token = try await client.fetchToken(clientID: "k", clientSecret: "s")
        XCTAssertEqual(token.scopes, [])
        XCTAssertNil(token.apiProducts)
    }

    func testFetchToken401IsInvalidCredentials() async {
        respond(401, #"{"error":"Unauthorized"}"#)
        await assertUSPSError(.invalidCredentials,
                              try await client.fetchToken(clientID: "k", clientSecret: "s"))
    }

    func testFetchToken400InvalidClientIsInvalidCredentials() async {
        respond(400, #"{"error":"invalid_client","error_description":"bad creds"}"#)
        await assertUSPSError(.invalidCredentials,
                              try await client.fetchToken(clientID: "k", clientSecret: "s"))
    }

    func testFetchToken400InvalidGrantIsInvalidCredentials() async {
        respond(400, #"{"error":"invalid_grant"}"#)
        await assertUSPSError(.invalidCredentials,
                              try await client.fetchToken(clientID: "k", clientSecret: "s"))
    }

    func testFetchTokenOther400FallsThroughToBadRequest() async {
        respond(400, #"{"error":"invalid_request","error_description":"grant_type is missing"}"#)
        await assertUSPSError(.badRequest(message: "USPS rejected the request.", details: []),
                              try await client.fetchToken(clientID: "k", clientSecret: "s"))
    }

    func testFetchTokenGarbageBodyIsDecodingError() async {
        respond(200, "not json at all")
        do {
            _ = try await client.fetchToken(clientID: "k", clientSecret: "s")
            XCTFail("expected decoding failure")
        } catch let error as USPSError {
            guard case .decoding = error else { return XCTFail("expected .decoding, got \(error)") }
        } catch {
            XCTFail("expected USPSError, got \(error)")
        }
    }

    // MARK: - Eligibility

    func testEligibilityQueryParametersOmitEmptySecondaryAddress() async throws {
        let captured = CapturedRequest()
        respond(200, Self.nestedEligibilityJSON) { captured.value = $0 }

        _ = try await client.checkEligibility(sampleAddress(), token: "tok")

        let request = try XCTUnwrap(captured.value)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/pickup/v3/carrier-pickup/eligibility")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let items = request.queryItems
        XCTAssertEqual(items["streetAddress"], "4120 Bingham Ave")
        XCTAssertEqual(items["city"], "Saint Louis")
        XCTAssertEqual(items["state"], "MO")
        XCTAssertEqual(items["ZIPCode"], "63116")
        XCTAssertNil(items["secondaryAddress"])
        XCTAssertNil(items["ZIPPlus4"])
    }

    func testEligibilityIncludesSecondaryAddressAndZIPPlus4WhenPresent() async throws {
        let captured = CapturedRequest()
        respond(200, Self.nestedEligibilityJSON) { captured.value = $0 }

        _ = try await client.checkEligibility(sampleAddress(secondary: "APT 2", zipPlus4: "2520"),
                                              token: "tok")

        let items = try XCTUnwrap(captured.value).queryItems
        XCTAssertEqual(items["secondaryAddress"], "APT 2")
        XCTAssertEqual(items["ZIPPlus4"], "2520")
    }

    func testEligibilityPercentEncodesReservedCharacters() async throws {
        let captured = CapturedRequest()
        respond(200, Self.nestedEligibilityJSON) { captured.value = $0 }

        let address = PostalAddress(streetAddress: "123 A+B St #4 & Co", secondaryAddress: nil,
                                    city: "Saint Louis", state: "MO", ZIPCode: "63116",
                                    ZIPPlus4: nil)
        _ = try await client.checkEligibility(address, token: "tok")

        let request = try XCTUnwrap(captured.value)
        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertTrue(url.contains("%2B"), url)
        XCTAssertTrue(url.contains("%23"), url)
        XCTAssertTrue(url.contains("%26"), url)
        XCTAssertFalse(url.contains("+"), url)

        let items = request.queryItems
        XCTAssertEqual(items["streetAddress"], "123 A+B St #4 & Co")
        XCTAssertEqual(items["city"], "Saint Louis")
    }

    func testEligibilityParsesNestedPickupAddressShape() async throws {
        respond(200, Self.nestedEligibilityJSON)
        let standardized = try await client.checkEligibility(sampleAddress(), token: "tok")
        XCTAssertEqual(standardized, PostalAddress(streetAddress: "4120 BINGHAM AVE",
                                                   secondaryAddress: nil, city: "SAINT LOUIS",
                                                   state: "MO", ZIPCode: "63116", ZIPPlus4: "2520"))
    }

    func testEligibilityParsesTopLevelShape() async throws {
        respond(200, Self.topLevelEligibilityJSON)
        let standardized = try await client.checkEligibility(sampleAddress(), token: "tok")
        XCTAssertEqual(standardized, PostalAddress(streetAddress: "1600 PENNSYLVANIA AVE NW",
                                                   secondaryAddress: "STE 100", city: "WASHINGTON",
                                                   state: "DC", ZIPCode: "20500", ZIPPlus4: "0003"))
    }

    func testEligibility400IsAddressNotEligibleWithUSPSMessage() async {
        respond(400, #"{"apiVersion":"3.0","error":{"code":"400","message":"Address not found."}}"#)
        await assertUSPSError(.addressNotEligible(message: "Address not found."),
                              try await client.checkEligibility(sampleAddress(), token: "tok"))
    }

    func testEligibility400WithoutMessageUsesFallbackCopy() async {
        respond(400, #"{"apiVersion":"3.0"}"#)
        await assertUSPSError(.addressNotEligible(message: "Address not eligible for carrier pickup."),
                              try await client.checkEligibility(sampleAddress(), token: "tok"))
    }

    /// The real 401 USPS returns when the developer app has no pickup product.
    private static let insufficientScopeBody = #"{"apiVersion":"/pickup/v3/","error":{"code":"401","message":"Insufficient OAuth scope.","errors":[{"title":"invalid_oauth_scope","detail":"The OAuth scope is invalid, missing or insufficient to access resource.","source":"Access Token"}]}}"#

    func testEligibility401WithScopeErrorIsInsufficientScope() async {
        respond(401, Self.insufficientScopeBody)
        await assertUSPSError(.insufficientScope(granted: []),
                              try await client.checkEligibility(sampleAddress(), token: "tok"))
    }

    func testSchedule401WithScopeErrorIsInsufficientScope() async {
        respond(401, Self.insufficientScopeBody)
        await assertUSPSError(.insufficientScope(granted: []),
                              try await client.schedulePickup(sampleRequest(), token: "tok"))
    }

    func testEligibility401WithScopeWordInMessageIsInsufficientScope() async {
        respond(401, #"{"error":{"code":"401","message":"The OAuth Scope is insufficient."}}"#)
        await assertUSPSError(.insufficientScope(granted: []),
                              try await client.checkEligibility(sampleAddress(), token: "tok"))
    }

    func testEligibility401IsInvalidCredentials() async {
        respond(401, "{}")
        await assertUSPSError(.invalidCredentials,
                              try await client.checkEligibility(sampleAddress(), token: "tok"))
    }

    // MARK: - Schedule

    func testSchedulePickupRequestShapeAndSuccess() async throws {
        let captured = CapturedRequest()
        respond(200, #"{"confirmationNumber":"WTC123456789","pickupDate":"2026-09-21"}"#) {
            captured.value = $0
        }

        let confirmation = try await client.schedulePickup(sampleRequest(), token: "tok")
        XCTAssertEqual(confirmation, PickupConfirmation(confirmationNumber: "WTC123456789",
                                                        pickupDate: "2026-09-21"))

        let request = try XCTUnwrap(captured.value)
        XCTAssertEqual(request.url?.absoluteString, "https://apis-tem.usps.com/pickup/v3/carrier-pickup")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")

        let body = try XCTUnwrap(request.bodyData)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["pickupDate"] as? String, "2026-09-21")
        XCTAssertEqual(json["nextAvailablePickup"] as? Bool, true)
        XCTAssertEqual(json["estimatedWeight"] as? Double, 3.5)
        let packages = try XCTUnwrap(json["packages"] as? [[String: Any]])
        XCTAssertEqual(packages.first?["packageType"] as? String, "PRIORITY_MAIL")
        XCTAssertEqual(packages.first?["packageCount"] as? Int, 2)
        let pickupAddress = try XCTUnwrap(json["pickupAddress"] as? [String: Any])
        XCTAssertEqual(pickupAddress["firstName"] as? String, "Todd")
        let contact = try XCTUnwrap(pickupAddress["contact"] as? [[String: Any]])
        XCTAssertEqual(contact.count, 2)
        XCTAssertEqual(contact[0]["email"] as? String, "todd@example.com")
        XCTAssertEqual(contact[1] as? [String: String], ["cellNumber": "3145551212"])
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("null"))
    }

    func testScheduleDecodesTheRealUSPSTestEnvironmentResponse() async throws {
        // Captured verbatim from apis-tem.usps.com on 2026-10-02. Note the
        // empty `{}` contact entry and the zero-count package lines.
        respond(200, #"""
        {"confirmationNumber":"EMC719435786","pickupDate":"2026-10-05","carrierPickupRequest":{"pickupDate":"2026-10-05","pickupAddress":{"firstName":"TEST","lastName":"USER","address":{"streetAddress":"475 LENFANT PLZ SW","city":"WASHINGTON","state":"DC","ZIPCode":"20260","ZIPPlus4":"0001"},"contact":[{"email":"TEST@EXAMPLE.COM"},{}]},"packages":[{"packageType":"PRIORITY_MAIL_EXPRESS","packageCount":0},{"packageType":"PRIORITY_MAIL","packageCount":1},{"packageType":"RETURNS","packageCount":0},{"packageType":"USPS_GROUND_ADVANTAGE","packageCount":0},{"packageType":"INTERNATIONAL","packageCount":0},{"packageType":"OTHER","packageCount":0}],"estimatedWeight":2,"pickupLocation":{"packageLocation":"FRONT_DOOR","dogPresent":false}}}
        """#)
        let confirmation = try await client.schedulePickup(sampleRequest(), token: "tok")
        XCTAssertEqual(confirmation, PickupConfirmation(confirmationNumber: "EMC719435786",
                                                        pickupDate: "2026-10-05"))
    }

    func testScheduleIgnoresUnknownPackageTypesInTheEcho() async throws {
        respond(200, #"""
        {"confirmationNumber":"EMC1","pickupDate":"2026-10-05","carrierPickupRequest":{"packages":[{"packageType":"BRAND_NEW_TYPE","packageCount":"x"}],"pickupAddress":{"contact":[{},{"weird":1}]}}}
        """#)
        let confirmation = try await client.schedulePickup(sampleRequest(), token: "tok")
        XCTAssertEqual(confirmation, PickupConfirmation(confirmationNumber: "EMC1", pickupDate: "2026-10-05"))
    }

    func testScheduleTopLevelPickupDateWinsOverNestedEcho() async throws {
        // `nextAvailablePickup` rolled the date forward: the nested object
        // echoes what was requested, the top level says what was scheduled.
        respond(200, #"""
        {"confirmationNumber":"WTC987","pickupDate":"2026-09-22",
         "carrierPickupRequest":{"confirmationNumber":"WTC987","pickupDate":"2026-09-21"}}
        """#)
        let confirmation = try await client.schedulePickup(sampleRequest(), token: "tok")
        XCTAssertEqual(confirmation, PickupConfirmation(confirmationNumber: "WTC987",
                                                        pickupDate: "2026-09-22"))
    }

    func testScheduleParsesNestedOnlyShape() async throws {
        respond(200, #"{"carrierPickupRequest":{"confirmationNumber":"WTC555","pickupDate":"2026-09-21"}}"#)
        let confirmation = try await client.schedulePickup(sampleRequest(), token: "tok")
        XCTAssertEqual(confirmation, PickupConfirmation(confirmationNumber: "WTC555",
                                                        pickupDate: "2026-09-21"))
    }

    func testSchedule403IsForbidden() async {
        respond(403, "{}")
        await assertUSPSError(.forbidden, try await client.schedulePickup(sampleRequest(), token: "t"))
    }

    func testSchedule429IsRateLimited() async {
        respond(429, "{}")
        await assertUSPSError(.rateLimited, try await client.schedulePickup(sampleRequest(), token: "t"))
    }

    func testSchedule503IsServiceUnavailable() async {
        respond(503, "{}")
        await assertUSPSError(.serviceUnavailable, try await client.schedulePickup(sampleRequest(), token: "t"))
    }

    func testSchedule502IsServiceUnavailable() async {
        respond(502, "{}")
        await assertUSPSError(.serviceUnavailable, try await client.schedulePickup(sampleRequest(), token: "t"))
    }

    func testSchedule400CollectsMessageAndDetails() async {
        let body = """
        {"apiVersion":"3.0","error":{"code":"400","message":"Invalid pickup request.",
        "errors":[{"code":"1","message":"pickupDate is not a valid pickup day"},
        {"code":"2","title":"weight too high"},
        {"code":"3","detail":"packageCount must be > 0"},
        {"code":"4"}]}}
        """
        respond(400, body)
        await assertUSPSError(.badRequest(message: "Invalid pickup request.",
                                          details: ["pickupDate is not a valid pickup day",
                                                    "weight too high",
                                                    "packageCount must be > 0"]),
                              try await client.schedulePickup(sampleRequest(), token: "t"))
    }

    func testSchedule400WithoutMessageUsesFallback() async {
        respond(400, "{}")
        await assertUSPSError(.badRequest(message: "USPS rejected the request.", details: []),
                              try await client.schedulePickup(sampleRequest(), token: "t"))
    }

    func testSchedule500IsUnexpectedWithBody() async {
        respond(500, "kaboom")
        await assertUSPSError(.unexpected(status: 500, body: "kaboom"),
                              try await client.schedulePickup(sampleRequest(), token: "t"))
    }

    func testUnexpectedBodyIsTrimmedTo2000Characters() async {
        let long = String(repeating: "x", count: 3000)
        respond(599, long)
        do {
            _ = try await client.schedulePickup(sampleRequest(), token: "t")
            XCTFail("expected failure")
        } catch let USPSError.unexpected(status, body) {
            XCTAssertEqual(status, 599)
            XCTAssertEqual(body.count, 2000)
        } catch {
            XCTFail("expected .unexpected, got \(error)")
        }
    }

    func testScheduleGarbage200IsDecodingError() async {
        respond(200, #"{"nope":true}"#)
        do {
            _ = try await client.schedulePickup(sampleRequest(), token: "t")
            XCTFail("expected decoding failure")
        } catch let error as USPSError {
            guard case .decoding = error else { return XCTFail("expected .decoding, got \(error)") }
        } catch {
            XCTFail("expected USPSError, got \(error)")
        }
    }

    // MARK: - Transport errors

    func testNotConnectedToInternetMapsToOffline() async {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await assertUSPSError(.offline, try await client.fetchToken(clientID: "k", clientSecret: "s"))
    }

    func testTimedOutMapsToOffline() async {
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        await assertUSPSError(.offline, try await client.schedulePickup(sampleRequest(), token: "t"))
    }

    func testOtherURLErrorMapsToUnexpectedWithZeroStatus() async {
        MockURLProtocol.handler = { _ in throw URLError(.badServerResponse) }
        do {
            _ = try await client.checkEligibility(sampleAddress(), token: "t")
            XCTFail("expected failure")
        } catch let USPSError.unexpected(status, body) {
            XCTAssertEqual(status, 0)
            XCTAssertFalse(body.isEmpty)
        } catch {
            XCTFail("expected .unexpected, got \(error)")
        }
    }

    // MARK: - Fixtures

    static let nestedEligibilityJSON = """
    {"pickupAddress":{"firstName":null,"lastName":null,"firm":null,
    "address":{"streetAddress":"4120 BINGHAM AVE","secondaryAddress":null,"city":"SAINT LOUIS",
    "state":"MO","ZIPCode":"63116","ZIPPlus4":"2520","urbanization":null},
    "contact":[{"eMail":null},{"phone":null,"extension":null}]}}
    """

    static let topLevelEligibilityJSON = """
    {"firstName":null,"lastName":null,"firm":null,
    "address":{"streetAddress":"1600 PENNSYLVANIA AVE NW","secondaryAddress":"STE 100",
    "city":"WASHINGTON","state":"DC","ZIPCode":"20500","ZIPPlus4":"0003","urbanization":null},
    "contact":[{"eMail":null},{"phone":null,"extension":null}]}
    """
}

/// Box used to smuggle the intercepted request out of the `@Sendable` handler.
final class CapturedRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: URLRequest?
    var value: URLRequest? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}
