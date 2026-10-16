import XCTest
import Combine
@testable import Pickup

/// Counts `notifyCredentialsNeeded()` calls.
final class SpyNotifier: Notifying, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func notifyCredentialsNeeded() { lock.withLock { _count += 1 } }
}

@MainActor
final class AppStateTests: XCTestCase {

    /// Thread-safe recorder for the URLs handed to the API factory.
    final class URLBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _urls: [URL] = []
        var urls: [URL] { lock.withLock { _urls } }
        func append(_ url: URL) { lock.withLock { _urls.append(url) } }
    }

    // MARK: - Fixtures

    /// Thursday, 2026-09-17 12:00 America/Chicago. The next available pickup
    /// day is Friday 2026-09-18.
    private static let fixedNow: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = PickupDateCalculator.timeZone
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 17,
                                                  hour: 12, minute: 0))!
    }()

    private let sampleContact = PickupContact(firstName: "Todd", lastName: "Anglin",
                                              firm: nil, phone: "3145551212",
                                              email: "todd@example.com")
    private let sampleAddress = PostalAddress(streetAddress: "4120 Bingham Ave",
                                              secondaryAddress: nil, city: "Saint Louis",
                                              state: "MO", ZIPCode: "63116", ZIPPlus4: nil)

    private var settings: SettingsStore!
    private var keychain: InMemoryKeychain!
    private var fake: FakeUSPSAPI!
    private var notifier: SpyNotifier!
    private var factoryURLs: URLBox!

    override func setUp() {
        super.setUp()
        settings = SettingsStore(defaults: UserDefaults(suiteName: "PickupTests.\(UUID().uuidString)")!)
        keychain = InMemoryKeychain()
        fake = FakeUSPSAPI()
        notifier = SpyNotifier()
        factoryURLs = URLBox()
    }

    private func makeState(credentials: Bool = false, address: Bool = false) -> AppState {
        if credentials {
            try? keychain.saveCredentials(id: "key", secret: "secret")
        }
        if address {
            settings.address = sampleAddress
            settings.contact = sampleContact
        }
        let fake = self.fake!
        let box = self.factoryURLs!
        return AppState(settings: settings,
                        keychain: keychain,
                        apiFactory: { url in box.append(url); return fake },
                        notifier: notifier,
                        now: { Self.fixedNow })
    }

    /// Polls `condition` until it is true or `timeout` elapses.
    private func waitFor(timeout: TimeInterval = 1.0, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private var firstAvailableDate: Date {
        PickupDateCalculator.availableDates(from: Self.fixedNow, count: 1)[0]
    }

    private func fillDraft(_ state: AppState) {
        state.draft.counts[.priorityMail] = 2
        state.draft.weight = 3
        state.draft.hazmatConfirmed = true
    }

    // MARK: - 1. start with no credentials

    func testStartWithoutCredentials() {
        let state = makeState()
        state.start()
        XCTAssertEqual(state.flow, .needsCredentials)
        XCTAssertEqual(state.credentialsStatus, .missing)
    }

    // MARK: - 2. start with credentials but no address

    func testStartWithCredentialsNoAddress() async {
        let state = makeState(credentials: true)
        state.start()
        XCTAssertEqual(state.flow, .needsAddress)
        await waitFor { state.credentialsStatus == .valid }
        XCTAssertEqual(state.credentialsStatus, .valid)
        XCTAssertEqual(fake.tokenCallCount, 1)
    }

    func testStartIsIdempotent() async {
        let state = makeState(credentials: true)
        state.start()
        state.start()
        await waitFor { state.credentialsStatus == .valid }
        XCTAssertEqual(fake.tokenCallCount, 1)
    }

    // MARK: - 3. start with credentials and address

    func testStartWithCredentialsAndAddress() {
        settings.defaultLocation = .backDoor
        let state = makeState(credentials: true, address: true)
        state.start()
        XCTAssertEqual(state.flow, .form)
        XCTAssertEqual(state.draft.selectedDate, firstAvailableDate)
        XCTAssertEqual(state.draft.location, settings.defaultLocation)
    }

    // MARK: - 4. start with revoked credentials

    func testStartWithInvalidCredentials() async {
        fake.tokenResult = .failure(USPSError.invalidCredentials)
        let state = makeState(credentials: true, address: true)
        state.start()
        await waitFor { state.flow == .needsCredentials }
        XCTAssertEqual(state.flow, .needsCredentials)
        XCTAssertEqual(state.credentialsStatus, .invalid)
        XCTAssertTrue(state.needsAttention)
        XCTAssertEqual(notifier.count, 1)
    }

    // MARK: - 5/6. saveCredentials

    func testSaveCredentialsSuccessWithoutAddress() async throws {
        let state = makeState()
        state.start()
        try await state.saveCredentials(id: "abc", secret: "xyz")
        let stored = try keychain.loadCredentials()
        XCTAssertEqual(stored?.id, "abc")
        XCTAssertEqual(stored?.secret, "xyz")
        XCTAssertEqual(state.flow, .needsAddress)
        XCTAssertEqual(state.credentialsStatus, .valid)
        XCTAssertFalse(state.needsAttention)
    }

    func testSaveCredentialsSuccessWithAddress() async throws {
        let state = makeState(address: true)
        state.start()
        try await state.saveCredentials(id: "abc", secret: "xyz")
        XCTAssertEqual(state.flow, .form)
    }

    func testSaveCredentialsFailureLeavesFlowUnchanged() async throws {
        fake.tokenResult = .failure(USPSError.invalidCredentials)
        let state = makeState()
        state.start()
        do {
            try await state.saveCredentials(id: "abc", secret: "xyz")
            XCTFail("expected saveCredentials to throw")
        } catch let error as USPSError {
            XCTAssertEqual(error, .invalidCredentials)
        }
        XCTAssertNil(try keychain.loadCredentials())
        XCTAssertEqual(state.flow, .needsCredentials)
    }

    func testRemoveCredentials() throws {
        let state = makeState(credentials: true, address: true)
        state.start()
        state.removeCredentials()
        XCTAssertNil(try keychain.loadCredentials())
        XCTAssertEqual(state.credentialsStatus, .missing)
        XCTAssertEqual(state.flow, .needsCredentials)
    }

    // MARK: - 7. validateAndSaveAddress

    func testValidateAndSaveAddressSuccess() async throws {
        let state = makeState(credentials: true)
        state.start()
        let standardized = try await state.validateAndSaveAddress(contact: sampleContact,
                                                                  address: sampleAddress)
        XCTAssertEqual(standardized, FakeUSPSAPI.defaultAddress)
        XCTAssertEqual(settings.address, FakeUSPSAPI.defaultAddress)
        XCTAssertEqual(settings.contact, sampleContact)
        // The address screen stays up so it can show the verified banner.
        XCTAssertEqual(state.flow, .needsAddress)
    }

    func testFinishAddressSetupMovesToTheForm() async throws {
        let state = makeState(credentials: true)
        state.start()
        XCTAssertEqual(state.flow, .needsAddress)
        _ = try await state.validateAndSaveAddress(contact: sampleContact, address: sampleAddress)
        XCTAssertEqual(state.flow, .needsAddress)

        state.finishAddressSetup()
        XCTAssertEqual(state.flow, .form)

        // From anywhere else it is a no-op: re-verifying from Settings must not
        // throw the user back onto the form mid-screen.
        fillDraft(state)
        await state.schedule()
        guard case .confirmed = state.flow else {
            return XCTFail("expected confirmed, got \(state.flow)")
        }
        state.finishAddressSetup()
        guard case .confirmed = state.flow else {
            XCTFail("finishAddressSetup should only act from .needsAddress")
            return
        }
    }

    func testValidateAndSaveAddressInvalidCredentials() async {
        fake.eligibilityResult = .failure(USPSError.invalidCredentials)
        let state = makeState(credentials: true)
        state.start()
        do {
            _ = try await state.validateAndSaveAddress(contact: sampleContact, address: sampleAddress)
            XCTFail("expected validateAndSaveAddress to throw")
        } catch let error as USPSError {
            XCTAssertEqual(error, .invalidCredentials)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(state.flow, .needsCredentials)
        XCTAssertTrue(state.needsAttention)
    }

    // MARK: - 8. schedule success

    func testScheduleSuccess() async {
        let state = makeState(credentials: true, address: true)
        state.start()
        fillDraft(state)
        await state.schedule()

        guard case .confirmed(let confirmation) = state.flow else {
            return XCTFail("expected confirmed, got \(state.flow)")
        }
        XCTAssertEqual(confirmation.confirmationNumber, "ABC123")
        XCTAssertEqual(settings.lastConfirmation, confirmation)

        let request = fake.lastScheduleRequest
        XCTAssertEqual(request?.packages, [PackageLine(packageType: .priorityMail, packageCount: 2)])
        XCTAssertEqual(request?.pickupDate, "2026-09-18")
        XCTAssertEqual(request?.nextAvailablePickup, true)
        XCTAssertNil(request?.pickupLocation.specialInstructions)
        XCTAssertEqual(request?.estimatedWeight, 3)
        XCTAssertEqual(request?.pickupAddress.firstName, "Todd")
    }

    // MARK: - 9. retryable failure

    func testScheduleRateLimitedThenRetry() async {
        fake.scheduleResult = .failure(USPSError.rateLimited)
        let state = makeState(credentials: true, address: true)
        state.start()
        fillDraft(state)
        await state.schedule()
        XCTAssertEqual(state.flow, .failed(.rateLimited, retryable: true))

        let draftBefore = state.draft
        state.retry()
        XCTAssertEqual(state.flow, .form)
        XCTAssertEqual(state.draft, draftBefore)
    }

    // MARK: - 10. invalid credentials during schedule

    func testScheduleInvalidCredentialsNotifiesOncePerEpisode() async throws {
        fake.scheduleResult = .failure(USPSError.invalidCredentials)
        let state = makeState(credentials: true, address: true)
        state.start()
        fillDraft(state)
        await state.schedule()
        XCTAssertEqual(state.flow, .needsCredentials)
        XCTAssertTrue(state.needsAttention)
        XCTAssertEqual(notifier.count, 1)

        // A second failure inside the same episode must not re-notify.
        state.retry()
        await state.schedule()
        XCTAssertEqual(notifier.count, 1)

        try await state.saveCredentials(id: "new", secret: "creds")
        XCTAssertFalse(state.needsAttention)
        XCTAssertEqual(state.flow, .form)

        fillDraft(state)
        await state.schedule()
        XCTAssertEqual(state.flow, .needsCredentials)
        XCTAssertEqual(notifier.count, 2)
    }

    // MARK: - 10b. 401 mid-session

    func testScheduleRetriesOnceWithAFreshTokenAfter401() async {
        // The token was accepted when issued but rejected by the pickup call.
        fake.scheduleResults = [.failure(USPSError.invalidCredentials)]
        let state = makeState(credentials: true, address: true)
        fillDraft(state)
        await state.schedule()

        guard case .confirmed(let confirmation) = state.flow else {
            return XCTFail("expected confirmed, got \(state.flow)")
        }
        XCTAssertEqual(confirmation.confirmationNumber, "ABC123")
        XCTAssertEqual(fake.scheduleCallCount, 2)
        XCTAssertEqual(fake.tokenCallCount, 2, "the retry should use a freshly fetched token")
        XCTAssertFalse(state.needsAttention)
        XCTAssertEqual(notifier.count, 0)
        XCTAssertEqual(state.credentialsStatus, .unknown)
    }

    func testScheduleTwice401NeedsCredentials() async {
        fake.scheduleResults = [.failure(USPSError.invalidCredentials),
                                .failure(USPSError.invalidCredentials)]
        let state = makeState(credentials: true, address: true)
        fillDraft(state)
        await state.schedule()

        XCTAssertEqual(state.flow, .needsCredentials)
        XCTAssertEqual(fake.scheduleCallCount, 2)
        XCTAssertEqual(state.credentialsStatus, .invalid)
        XCTAssertTrue(state.needsAttention)
        XCTAssertEqual(notifier.count, 1)
    }

    func testValidateAndSaveAddressRetriesOnceAfter401() async throws {
        fake.eligibilityResults = [.failure(USPSError.invalidCredentials)]
        let state = makeState(credentials: true)

        let standardized = try await state.validateAndSaveAddress(contact: sampleContact,
                                                                  address: sampleAddress)
        XCTAssertEqual(standardized, FakeUSPSAPI.defaultAddress)
        XCTAssertEqual(fake.eligibilityCallCount, 2)
        XCTAssertEqual(fake.tokenCallCount, 2)
        XCTAssertFalse(state.needsAttention)
        XCTAssertEqual(notifier.count, 0)
    }

    // MARK: - 10c. missing pickup scope

    func testScheduleInsufficientScopeFailsWithoutRetryOrReauth() async {
        fake.setScopes(["addresses", "locations"])
        fake.scheduleResult = .failure(USPSError.insufficientScope(granted: []))
        let state = makeState(credentials: true, address: true)
        fillDraft(state)
        await state.schedule()

        guard case .failed(let error, let retryable) = state.flow else {
            return XCTFail("expected failed, got \(state.flow)")
        }
        XCTAssertFalse(retryable)
        XCTAssertEqual(error, .insufficientScope(granted: ["addresses", "locations"]),
                       "the granted scopes should be filled in from the cached token")
        XCTAssertEqual(fake.scheduleCallCount, 1, "an insufficient scope must not be retried")
        XCTAssertEqual(fake.tokenCallCount, 1, "a fresh token would have the same scopes")
        XCTAssertFalse(state.needsAttention)
        XCTAssertEqual(notifier.count, 0)
        XCTAssertNotEqual(state.credentialsStatus, .invalid)
    }

    func testValidateAndSaveAddressInsufficientScopeRethrowsAndKeepsFlow() async {
        fake.setScopes(["addresses", "locations"])
        fake.eligibilityResult = .failure(USPSError.insufficientScope(granted: []))
        let state = makeState(credentials: true)
        state.start()

        do {
            _ = try await state.validateAndSaveAddress(contact: sampleContact, address: sampleAddress)
            XCTFail("expected validateAndSaveAddress to throw")
        } catch let error as USPSError {
            XCTAssertEqual(error, .insufficientScope(granted: ["addresses", "locations"]))
        } catch {
            XCTFail("unexpected error \(error)")
        }

        XCTAssertEqual(state.flow, .needsAddress, "the address screen shows this inline")
        XCTAssertEqual(fake.eligibilityCallCount, 1)
        XCTAssertFalse(state.needsAttention)
        XCTAssertEqual(notifier.count, 0)
    }

    func testSaveCredentialsWithoutPickupScopeWarnsButStaysValid() async throws {
        fake.setScopes(["addresses", "locations"])
        let state = makeState()
        state.start()
        try await state.saveCredentials(id: "abc", secret: "xyz")

        XCTAssertEqual(state.credentialsStatus, .valid)
        XCTAssertEqual(state.flow, .needsAddress, "the flow still advances")
        XCTAssertEqual(state.grantedScopes, ["addresses", "locations"])
        XCTAssertEqual(state.scopeWarning, .insufficientScope(granted: ["addresses", "locations"]))
    }

    func testSaveCredentialsWithPickupScopeClearsTheWarning() async throws {
        fake.setScopes(["addresses", "locations"])
        let state = makeState()
        state.start()
        try await state.saveCredentials(id: "abc", secret: "xyz")
        XCTAssertNotNil(state.scopeWarning)

        fake.setScopes(["addresses", "pickup"])
        try await state.saveCredentials(id: "abc", secret: "xyz")
        XCTAssertNil(state.scopeWarning)
        XCTAssertEqual(state.grantedScopes, ["addresses", "pickup"])
        XCTAssertEqual(state.credentialsStatus, .valid)
    }

    func testRealCarrierPickupScopeNameLeavesNoWarning() async throws {
        // What USPS actually grants an app with the Carrier Pickup product.
        fake.setScopes("addresses carrier-pickup labels".split(separator: " ").map(String.init))
        let state = makeState()
        state.start()
        try await state.saveCredentials(id: "abc", secret: "xyz")
        XCTAssertNil(state.scopeWarning)
        XCTAssertEqual(state.grantedScopes, ["addresses", "carrier-pickup", "labels"])
    }

    func testTokenAllowsPickupAcceptsEitherScopeName() {
        let now = Date()
        XCTAssertTrue(OAuthToken(accessToken: "t", expiresAt: now, scopes: ["carrier-pickup"]).allowsPickup)
        XCTAssertTrue(OAuthToken(accessToken: "t", expiresAt: now, scopes: ["pickup"]).allowsPickup)
        XCTAssertTrue(OAuthToken(accessToken: "t", expiresAt: now, scopes: []).allowsPickup)
        XCTAssertFalse(OAuthToken(accessToken: "t", expiresAt: now, scopes: ["addresses", "labels"]).allowsPickup)
        XCTAssertTrue(OAuthToken.scopesAllowPickup(["addresses", "carrier-pickup"]))
        XCTAssertFalse(OAuthToken.scopesAllowPickup(["carrier-pickup-x"]))
    }

    func testStartWithoutPickupScopeSetsTheWarning() async {
        fake.setScopes(["addresses", "locations"])
        let state = makeState(credentials: true, address: true)
        state.start()
        await waitFor { state.scopeWarning != nil }
        XCTAssertEqual(state.scopeWarning, .insufficientScope(granted: ["addresses", "locations"]))
        XCTAssertEqual(state.credentialsStatus, .valid)
        XCTAssertEqual(state.flow, .form)
    }

    func testStartWithAnUnknownScopeListLeavesNoWarning() async {
        let state = makeState(credentials: true, address: true)
        state.start()
        await waitFor { state.credentialsStatus == .valid }
        XCTAssertNil(state.scopeWarning, "an empty scope list says nothing about the app's products")
        XCTAssertEqual(state.grantedScopes, [])
    }

    // MARK: - 11. non-retryable failure

    func testScheduleForbidden() async {
        fake.scheduleResult = .failure(USPSError.forbidden)
        let state = makeState(credentials: true, address: true)
        state.start()
        fillDraft(state)
        await state.schedule()
        XCTAssertEqual(state.flow, .failed(.forbidden, retryable: false))
    }

    func testScheduleNonUSPSErrorIsRetryable() async {
        struct Boom: Error {}
        fake.scheduleResult = .failure(Boom())
        let state = makeState(credentials: true, address: true)
        state.start()
        fillDraft(state)
        await state.schedule()
        guard case .failed(let error, let retryable) = state.flow else {
            return XCTFail("expected failed, got \(state.flow)")
        }
        XCTAssertTrue(retryable)
        if case .unexpected(let status, _) = error {
            XCTAssertEqual(status, 0)
        } else {
            XCTFail("expected .unexpected, got \(error)")
        }
    }

    // MARK: - 12. cannot submit

    func testScheduleNoOpWhenDraftIncomplete() async {
        let state = makeState(credentials: true, address: true)
        state.start()
        await state.schedule()
        XCTAssertEqual(state.flow, .form)
        XCTAssertEqual(fake.scheduleCallCount, 0)
    }

    // MARK: - History

    func testScheduleSuccessAddsAHistoryRecord() async throws {
        // USPS confirms a different day than the one requested.
        fake.scheduleResult = .success(PickupConfirmation(confirmationNumber: "WTC42",
                                                          pickupDate: "2026-09-21"))
        let state = makeState(credentials: true, address: true)
        state.start()
        fillDraft(state)
        state.draft.counts[.groundAdvantage] = 1
        state.draft.location = .porch
        await state.schedule()

        XCTAssertEqual(settings.history.count, 1)
        let record = try XCTUnwrap(settings.history.first)
        XCTAssertEqual(record.confirmationNumber, "WTC42")
        XCTAssertEqual(record.pickupDate, "2026-09-21")
        XCTAssertEqual(fake.lastScheduleRequest?.pickupDate, "2026-09-18")
        XCTAssertEqual(record.packages, [PackageLine(packageType: .groundAdvantage, packageCount: 1),
                                         PackageLine(packageType: .priorityMail, packageCount: 2)])
        XCTAssertEqual(record.totalPackages, 3)
        XCTAssertEqual(record.estimatedWeight, 3)
        XCTAssertEqual(record.location, .porch)
        XCTAssertEqual(record.addressLine, "4120 Bingham Ave, Saint Louis MO")
        XCTAssertEqual(record.createdAt, Self.fixedNow)
    }

    func testFailedScheduleAddsNoHistory() async {
        fake.scheduleResult = .failure(USPSError.rateLimited)
        let state = makeState(credentials: true, address: true)
        state.start()
        fillDraft(state)
        await state.schedule()
        XCTAssertEqual(settings.history, [])
    }

    func testShowAndCloseHistoryFromTheForm() {
        let state = makeState(credentials: true, address: true)
        state.start()
        state.draft.counts[.returns] = 4
        state.showHistory()
        XCTAssertEqual(state.flow, .history)
        state.closeHistory()
        XCTAssertEqual(state.flow, .form)
        // The draft in progress survives the detour.
        XCTAssertEqual(state.draft.counts[.returns], 4)
    }

    func testShowHistoryFromConfirmationThenBackGivesAFreshForm() async {
        let state = makeState(credentials: true, address: true)
        state.start()
        fillDraft(state)
        await state.schedule()
        guard case .confirmed = state.flow else { return XCTFail("expected confirmed, got \(state.flow)") }
        state.showHistory()
        XCTAssertEqual(state.flow, .history)
        state.closeHistory()
        XCTAssertEqual(state.flow, .form)
        XCTAssertEqual(state.draft.totalPackages, 0)
    }

    func testShowHistoryIgnoredOutsideFormAndConfirmation() {
        let state = makeState()
        state.start()
        XCTAssertEqual(state.flow, .needsCredentials)
        state.showHistory()
        XCTAssertEqual(state.flow, .needsCredentials)
        state.closeHistory()
        XCTAssertEqual(state.flow, .needsCredentials)
    }

    // MARK: - 13. schedule another

    func testScheduleAnotherResetsDraft() async {
        let state = makeState(credentials: true, address: true)
        state.start()
        fillDraft(state)
        await state.schedule()
        state.scheduleAnother()
        XCTAssertEqual(state.flow, .form)
        XCTAssertEqual(state.draft.totalPackages, 0)
        XCTAssertFalse(state.draft.hazmatConfirmed)
        XCTAssertEqual(state.draft.counts.count, PackageType.allCases.count)
        XCTAssertEqual(state.draft.selectedDate, firstAvailableDate)
    }

    // MARK: - 14. PickupDraft.request

    func testDraftRequestOnlyIncludesNonZeroLinesInAllCasesOrder() {
        var draft = PickupDraft.fromDefaults(settings, now: Self.fixedNow)
        draft.counts[.other] = 1
        draft.counts[.groundAdvantage] = 3
        draft.counts[.priorityMail] = 0
        draft.instructions = "  leave by the gate  "
        draft.weight = 4.5

        let request = draft.request(address: sampleAddress, contact: sampleContact)
        XCTAssertEqual(request.packages, [
            PackageLine(packageType: .groundAdvantage, packageCount: 3),
            PackageLine(packageType: .other, packageCount: 1)
        ])
        XCTAssertEqual(request.pickupLocation.specialInstructions, "leave by the gate")
        XCTAssertEqual(request.pickupDate, "2026-09-18")
        XCTAssertTrue(request.nextAvailablePickup)
    }

    func testDraftCanSubmit() {
        var draft = PickupDraft.fromDefaults(settings, now: Self.fixedNow)
        XCTAssertFalse(draft.canSubmit)
        draft.counts[.returns] = 1
        XCTAssertFalse(draft.canSubmit)
        draft.hazmatConfirmed = true
        XCTAssertTrue(draft.canSubmit)
        draft.weight = 0
        XCTAssertFalse(draft.canSubmit)
    }

    func testDraftWithLocationOtherNeedsInstructions() {
        var draft = PickupDraft.fromDefaults(settings, now: Self.fixedNow)
        draft.counts[.priorityMail] = 1
        draft.hazmatConfirmed = true
        draft.instructions = ""
        XCTAssertFalse(draft.instructionsMissing)
        XCTAssertTrue(draft.canSubmit)

        draft.location = .other
        XCTAssertTrue(draft.instructionsMissing)
        XCTAssertFalse(draft.canSubmit)

        draft.instructions = "   "
        XCTAssertTrue(draft.instructionsMissing, "whitespace is not an instruction")
        XCTAssertFalse(draft.canSubmit)

        draft.instructions = "Behind the garage"
        XCTAssertFalse(draft.instructionsMissing)
        XCTAssertTrue(draft.canSubmit)
    }

    func testDraftDefaultsComeFromSettings() {
        settings.defaultLocation = .sideDoor
        settings.defaultInstructions = "ring bell"
        settings.dogPresent = true
        settings.defaultWeight = 7
        let draft = PickupDraft.fromDefaults(settings, now: Self.fixedNow)
        XCTAssertEqual(draft.location, .sideDoor)
        XCTAssertEqual(draft.instructions, "ring bell")
        XCTAssertTrue(draft.dogPresent)
        XCTAssertEqual(draft.weight, 7)
        XCTAssertEqual(draft.counts.count, PackageType.allCases.count)
        XCTAssertEqual(draft.totalPackages, 0)
    }

    // MARK: - 15. environment toggle

    func testTogglingTestEnvironmentRebuildsAPI() async {
        let state = makeState(credentials: true, address: true)
        state.start()
        XCTAssertEqual(factoryURLs.urls, [BaseURL.production])

        settings.useTestEnvironment = true
        await waitFor { self.factoryURLs.urls.count == 2 }
        XCTAssertEqual(factoryURLs.urls, [BaseURL.production, BaseURL.test])
        withExtendedLifetime(state) {}
    }

    /// TEM credentials are different from production ones, so the status pill
    /// has to stop claiming the old environment's verdict.
    func testTogglingTestEnvironmentReverifiesCredentials() async {
        let state = makeState(credentials: true, address: true)
        state.start()
        await waitFor { state.credentialsStatus == .valid }
        XCTAssertEqual(fake.tokenCallCount, 1)

        fake.tokenResult = .failure(USPSError.invalidCredentials)
        settings.useTestEnvironment = true
        await waitFor { state.credentialsStatus == .invalid }
        XCTAssertEqual(state.credentialsStatus, .invalid)
        XCTAssertGreaterThanOrEqual(fake.tokenCallCount, 2)
        withExtendedLifetime(state) {}
    }

    // MARK: - 16. credential key prefix

    func testCredentialKeyPrefixTracksTheStoredKey() async throws {
        let state = makeState()
        state.start()
        XCTAssertNil(state.credentialKeyPrefix)

        try await state.saveCredentials(id: "ABCDEFGH", secret: "xyz")
        XCTAssertEqual(state.credentialKeyPrefix, "ABCD")

        state.removeCredentials()
        XCTAssertNil(state.credentialKeyPrefix)
    }

    func testCredentialKeyPrefixSurvivesRejection() async {
        try? keychain.saveCredentials(id: "ABCDEFGH", secret: "xyz")
        fake.tokenResult = .failure(USPSError.invalidCredentials)
        let state = makeState(address: true)
        state.start()
        await waitFor { state.credentialsStatus == .invalid }
        // The user needs to see *which* key USPS refused.
        XCTAssertEqual(state.credentialKeyPrefix, "ABCD")
    }

    func testSaveCredentialsReportsAKeychainFailure() async {
        let state = makeState()
        state.start()
        keychain.failWrites = true
        do {
            try await state.saveCredentials(id: "abc", secret: "xyz")
            XCTFail("expected saveCredentials to throw")
        } catch let error as USPSError {
            guard case .unexpected(let status, let body) = error else {
                return XCTFail("expected .unexpected, got \(error)")
            }
            XCTAssertEqual(status, 0)
            XCTAssertTrue(body.contains("Keychain"), body)
            XCTAssertTrue(body.contains("-34018"), body)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
