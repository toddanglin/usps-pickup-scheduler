import XCTest
@testable import PickupBar

/// "Modify…" and "Cancel pickup…" from the history.
@MainActor
final class AppStateModifyCancelTests: XCTestCase {

    /// Thursday, 2026-09-17 12:00 America/Chicago.
    private static let fixedNow: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = PickupDateCalculator.timeZone
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 12))!
    }()

    private let contact = PickupContact(firstName: "Todd", lastName: "Anglin", firm: nil,
                                        phone: "3145551212", email: "todd@example.com")
    private let address = PostalAddress(streetAddress: "4120 Bingham Ave", secondaryAddress: nil,
                                        city: "Saint Louis", state: "MO", ZIPCode: "63116", ZIPPlus4: nil)

    private var settings: SettingsStore!
    private var keychain: InMemoryKeychain!
    private var fake: FakeUSPSAPI!

    private var availableDates: [Date] { PickupDateCalculator.availableDates(from: Self.fixedNow) }
    private var secondDay: String { PickupDateCalculator.apiDateString(availableDates[1]) }

    override func setUp() {
        super.setUp()
        settings = SettingsStore(defaults: UserDefaults(suiteName: "PickupBarTests.\(UUID().uuidString)")!)
        keychain = InMemoryKeychain()
        fake = FakeUSPSAPI()
    }

    /// A configured user looking at the history, which holds `record()`.
    private func makeStateInHistory() -> AppState {
        try? keychain.saveCredentials(id: "key", secret: "secret")
        settings.address = address
        settings.contact = contact
        settings.addToHistory(record())
        let fake = self.fake!
        let state = AppState(settings: settings, keychain: keychain,
                             apiFactory: { _ in fake }, notifier: SpyNotifier(),
                             now: { Self.fixedNow })
        state.start()
        state.showHistory()
        XCTAssertEqual(state.flow, .history)
        return state
    }

    private func record(date: String? = nil) -> PickupRecord {
        PickupRecord(confirmationNumber: "WTC1", pickupDate: date ?? secondDay,
                     createdAt: Self.fixedNow.addingTimeInterval(-3600),
                     packages: [PackageLine(packageType: .priorityMail, packageCount: 1)],
                     estimatedWeight: 2, location: .sideDoor, addressLine: "4120 BINGHAM AVE, SAINT LOUIS MO")
    }

    private func fetchedRequest(date: String) -> SchedulePickupRequest {
        SchedulePickupRequest(
            pickupDate: date,
            pickupAddress: PickupAddress(contact: contact, address: address),
            packages: PackageType.allCases.map { type in
                PackageLine(packageType: type,
                            packageCount: type == .groundAdvantage ? 3 : (type == .priorityMail ? 2 : 0))
            },
            estimatedWeight: 3,
            pickupLocation: PickupLocation(packageLocation: .porch, specialInstructions: "By the gate",
                                           dogPresent: true),
            nextAvailablePickup: false)
    }

    private func fetched(date: String? = nil, etag: String = "etag-1",
                         withRequest: Bool = true) -> FetchedPickup {
        let date = date ?? secondDay
        return FetchedPickup(confirmation: PickupConfirmation(confirmationNumber: "WTC1", pickupDate: date),
                             request: withRequest ? fetchedRequest(date: date) : nil,
                             etag: etag)
    }

    private var staleETag: USPSError {
        .badRequest(message: "The resource, /pickup/v3/carrier-pickup/WTC1 has been modified since the update indicated by the If-Match request header.",
                    details: [])
    }

    private var alreadyCancelled: USPSError {
        .badRequest(message: "Pickup already cancelled.", details: ["Pickup already cancelled."])
    }

    // MARK: - beginModify

    func testBeginModifyPrefillsTheFormFromUSPS() async {
        let state = makeStateInHistory()
        fake.fetchResult = .success(fetched())

        await state.beginModify(record())

        XCTAssertEqual(state.flow, .modifying(confirmationNumber: "WTC1"))
        XCTAssertEqual(fake.lastFetchConfirmationNumber, "WTC1")
        XCTAssertEqual(state.pendingEdit, PendingEdit(confirmationNumber: "WTC1", etag: "etag-1"))
        XCTAssertEqual(PickupDateCalculator.apiDateString(state.draft.selectedDate), secondDay)
        XCTAssertEqual(state.draft.location, .porch)
        XCTAssertEqual(state.draft.instructions, "By the gate")
        XCTAssertTrue(state.draft.dogPresent)
        XCTAssertEqual(state.draft.counts[.groundAdvantage], 3)
        XCTAssertEqual(state.draft.counts[.priorityMail], 2)
        XCTAssertEqual(state.draft.counts[.returns], 0)
        XCTAssertEqual(state.draft.counts.count, PackageType.allCases.count)
        XCTAssertEqual(state.draft.weight, 3)
        XCTAssertFalse(state.draft.hazmatConfirmed, "the hazmat promise is made again each time")
    }

    func testBeginModifyWithAPastDateSelectsTheFirstAvailableDay() async {
        let state = makeStateInHistory()
        fake.fetchResult = .success(fetched(date: "2026-09-10"))

        await state.beginModify(record())

        XCTAssertEqual(state.flow, .modifying(confirmationNumber: "WTC1"))
        XCTAssertEqual(state.draft.selectedDate, availableDates[0])
    }

    func testBeginModifyWithAnUnofferedDateSelectsTheFirstAvailableDay() async {
        let state = makeStateInHistory()
        // A Sunday is never offered.
        fake.fetchResult = .success(fetched(date: "2026-09-20"))
        await state.beginModify(record())
        XCTAssertEqual(state.draft.selectedDate, availableDates[0])
    }

    func testBeginModifyFallsBackToTheLocalRecord() async {
        let state = makeStateInHistory()
        fake.fetchResult = .success(fetched(withRequest: false))

        await state.beginModify(record())

        XCTAssertEqual(state.flow, .modifying(confirmationNumber: "WTC1"))
        XCTAssertEqual(state.draft.counts[.priorityMail], 1)
        XCTAssertEqual(state.draft.totalPackages, 1)
        XCTAssertEqual(state.draft.weight, 2)
        XCTAssertEqual(state.draft.location, .sideDoor)
        XCTAssertEqual(PickupDateCalculator.apiDateString(state.draft.selectedDate), secondDay)
        XCTAssertFalse(state.draft.hazmatConfirmed)
    }

    func testBeginModifyFailureRetriesBackToHistory() async {
        let state = makeStateInHistory()
        fake.fetchResult = .failure(USPSError.serviceUnavailable)

        await state.beginModify(record())

        XCTAssertEqual(state.flow, .failed(.serviceUnavailable, retryable: true))
        XCTAssertTrue(state.retryReturnsToHistory)
        XCTAssertNil(state.pendingEdit)
        state.retry()
        XCTAssertEqual(state.flow, .history)
    }

    func testBeginModifyRetriesOnceWithAFreshTokenAfter401() async {
        let state = makeStateInHistory()
        fake.fetchResults = [.failure(USPSError.invalidCredentials), .success(fetched())]
        await state.beginModify(record())
        XCTAssertEqual(state.flow, .modifying(confirmationNumber: "WTC1"))
        XCTAssertEqual(fake.fetchCallCount, 2)
    }

    func testBeginModifyWithBadCredentialsNeedsCredentials() async {
        let state = makeStateInHistory()
        fake.fetchResult = .failure(USPSError.invalidCredentials)
        await state.beginModify(record())
        XCTAssertEqual(state.flow, .needsCredentials)
    }

    // MARK: - saveModification

    private func stateModifying() async -> AppState {
        let state = makeStateInHistory()
        fake.fetchResult = .success(fetched())
        await state.beginModify(record())
        XCTAssertEqual(state.flow, .modifying(confirmationNumber: "WTC1"))
        return state
    }

    func testSaveModificationPutsTheDraftAndUpdatesTheHistory() async throws {
        let state = await stateModifying()
        settings.lastConfirmation = PickupConfirmation(confirmationNumber: "WTC1", pickupDate: secondDay)
        state.draft.weight = 4
        state.draft.hazmatConfirmed = true
        // USPS hands out a fresh ETag on the GET right before the PUT.
        fake.fetchResult = .success(fetched(etag: "etag-2"))
        let thirdDay = PickupDateCalculator.apiDateString(availableDates[2])
        fake.updateResult = .success(FetchedPickup(
            confirmation: PickupConfirmation(confirmationNumber: "WTC1", pickupDate: thirdDay),
            request: nil, etag: "etag-3"))

        await state.saveModification()

        let update = try XCTUnwrap(fake.lastUpdate)
        XCTAssertEqual(update.confirmationNumber, "WTC1")
        XCTAssertEqual(update.etag, "etag-2", "the PUT uses the ETag from the GET just before it")
        XCTAssertFalse(update.request.nextAvailablePickup, "PUT must not ask for the next available day")
        XCTAssertEqual(update.request.estimatedWeight, 4)
        XCTAssertEqual(update.request.packages, [PackageLine(packageType: .groundAdvantage, packageCount: 3),
                                                 PackageLine(packageType: .priorityMail, packageCount: 2)])
        XCTAssertEqual(update.request.pickupAddress, PickupAddress(contact: contact, address: address))
        XCTAssertEqual(Array(fake.calls.suffix(2)), ["fetch", "update"])

        let confirmation = PickupConfirmation(confirmationNumber: "WTC1", pickupDate: thirdDay)
        XCTAssertEqual(state.flow, .confirmed(confirmation))
        XCTAssertEqual(state.confirmationMode, .updated)
        XCTAssertNil(state.pendingEdit)
        XCTAssertEqual(settings.lastConfirmation, confirmation)

        let stored = try XCTUnwrap(settings.history.first { $0.confirmationNumber == "WTC1" })
        XCTAssertEqual(stored.pickupDate, thirdDay)
        XCTAssertEqual(stored.estimatedWeight, 4)
        XCTAssertEqual(stored.totalPackages, 5)
        XCTAssertEqual(stored.location, .porch)
        XCTAssertEqual(stored.updatedAt, Self.fixedNow)
        XCTAssertEqual(stored.status, .scheduled)
        XCTAssertEqual(stored.createdAt, record().createdAt)
        XCTAssertEqual(settings.history.count, 1)

        // "Done" goes back to the history with a fresh draft.
        state.showHistory()
        XCTAssertEqual(state.flow, .history)
        XCTAssertEqual(state.draft.totalPackages, 0)
    }

    func testSaveModificationLeavesAnUnrelatedLastConfirmationAlone() async {
        let state = await stateModifying()
        let other = PickupConfirmation(confirmationNumber: "WTC9", pickupDate: secondDay)
        settings.lastConfirmation = other
        state.draft.hazmatConfirmed = true
        await state.saveModification()
        XCTAssertEqual(settings.lastConfirmation, other)
    }

    func testSaveModificationNoOpWhenTheDraftCannotBeSubmitted() async {
        let state = await stateModifying()
        XCTAssertFalse(state.draft.hazmatConfirmed)
        await state.saveModification()
        XCTAssertEqual(fake.updateCallCount, 0)
        XCTAssertEqual(state.flow, .modifying(confirmationNumber: "WTC1"))
    }

    func testSaveModificationStaleETagIsRetryableAndKeepsTheEdits() async {
        let state = await stateModifying()
        state.draft.weight = 9
        state.draft.hazmatConfirmed = true
        fake.updateResult = .failure(staleETag)

        await state.saveModification()

        XCTAssertEqual(state.flow, .failed(staleETag, retryable: true))
        XCTAssertFalse(state.retryReturnsToHistory)
        state.retry()
        XCTAssertEqual(state.flow, .modifying(confirmationNumber: "WTC1"))
        XCTAssertEqual(state.draft.weight, 9)
        XCTAssertNotNil(state.pendingEdit)

        // Saving again fetches a fresh ETag first.
        fake.fetchResult = .success(fetched(etag: "etag-fresh"))
        fake.updateResult = .success(fetched(etag: "etag-after"))
        await state.saveModification()
        XCTAssertEqual(fake.lastUpdate?.etag, "etag-fresh")
        XCTAssertEqual(state.confirmationMode, .updated)
    }

    func testSaveModificationScopeErrorFails() async {
        let state = await stateModifying()
        state.draft.hazmatConfirmed = true
        fake.updateResult = .failure(USPSError.insufficientScope(granted: []))
        await state.saveModification()
        guard case .failed(.insufficientScope, false) = state.flow else {
            return XCTFail("got \(state.flow)")
        }
    }

    func testSaveModificationBadCredentialsNeedsCredentials() async {
        let state = await stateModifying()
        state.draft.hazmatConfirmed = true
        fake.updateResult = .failure(USPSError.invalidCredentials)
        await state.saveModification()
        XCTAssertEqual(state.flow, .needsCredentials)
    }

    func testCancelModificationDiscardsTheEdit() async {
        let state = await stateModifying()
        state.draft.weight = 9
        state.cancelModification()
        XCTAssertEqual(state.flow, .history)
        XCTAssertNil(state.pendingEdit)
        XCTAssertEqual(state.draft.totalPackages, 0)
        XCTAssertEqual(fake.updateCallCount, 0)
    }

    func testANewScheduleConfirmsInScheduledMode() async {
        let state = await stateModifying()
        state.draft.hazmatConfirmed = true
        await state.saveModification()
        XCTAssertEqual(state.confirmationMode, .updated)
        state.scheduleAnother()
        state.draft.counts[.priorityMail] = 1
        state.draft.hazmatConfirmed = true
        await state.schedule()
        XCTAssertEqual(state.confirmationMode, .scheduled)
    }

    // MARK: - cancelPickup

    func testCancelPickupGetsFirstThenDeletesWithThatETag() async throws {
        let state = makeStateInHistory()
        fake.fetchResult = .success(fetched(etag: "etag-for-delete"))

        await state.cancelPickup(record())

        XCTAssertEqual(fake.calls, ["fetch", "cancel"])
        XCTAssertEqual(fake.lastCancel?.confirmationNumber, "WTC1")
        XCTAssertEqual(fake.lastCancel?.etag, "etag-for-delete")
        XCTAssertEqual(state.flow, .history)
        let stored = try XCTUnwrap(settings.history.first)
        XCTAssertEqual(stored.status, .cancelled)
        XCTAssertEqual(stored.updatedAt, Self.fixedNow)
        XCTAssertFalse(stored.isUpcoming(asOf: Self.fixedNow))
    }

    func testCancelPickupAlreadyCancelledIsIdempotent() async {
        let state = makeStateInHistory()
        fake.cancelResult = .failure(alreadyCancelled)

        await state.cancelPickup(record())

        XCTAssertEqual(state.flow, .history)
        XCTAssertEqual(settings.history.first?.status, .cancelled)
    }

    func testCancelPickupOtherFailureRetriesBackToHistory() async {
        let state = makeStateInHistory()
        let pastDate = USPSError.badRequest(message: "Pickup date is in the past.", details: [])
        fake.cancelResult = .failure(pastDate)

        await state.cancelPickup(record())

        XCTAssertEqual(state.flow, .failed(pastDate, retryable: false))
        XCTAssertTrue(state.retryReturnsToHistory)
        XCTAssertEqual(settings.history.first?.status, .scheduled)
        state.retry()
        XCTAssertEqual(state.flow, .history)
    }

    func testCancelPickupFetchFailureNeverDeletes() async {
        let state = makeStateInHistory()
        fake.fetchResult = .failure(USPSError.offline)

        await state.cancelPickup(record())

        XCTAssertEqual(fake.cancelCallCount, 0)
        XCTAssertEqual(state.flow, .failed(.offline, retryable: true))
        state.retry()
        XCTAssertEqual(state.flow, .history)
    }

    func testCancelPickupRetriesTheDeleteWithAFreshTokenAfter401() async {
        let state = makeStateInHistory()
        fake.cancelResults = [.failure(USPSError.invalidCredentials), .success(())]
        await state.cancelPickup(record())
        XCTAssertEqual(fake.cancelCallCount, 2)
        XCTAssertEqual(settings.history.first?.status, .cancelled)
    }

    func testScheduleFailureStillRetriesToTheForm() async {
        let state = makeStateInHistory()
        state.closeHistory()
        state.draft.counts[.priorityMail] = 1
        state.draft.hazmatConfirmed = true
        fake.scheduleResult = .failure(USPSError.serviceUnavailable)
        await state.schedule()
        XCTAssertFalse(state.retryReturnsToHistory)
        state.retry()
        XCTAssertEqual(state.flow, .form)
    }
}
