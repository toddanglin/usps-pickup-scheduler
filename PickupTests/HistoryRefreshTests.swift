import XCTest
@testable import Pickup

/// The quiet "check with USPS" that runs whenever "Scheduled pickups" opens,
/// and the red dot it leaves on pickups that changed on usps.com.
@MainActor
final class HistoryRefreshTests: XCTestCase {

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

    private var suiteName: String!
    private var settings: SettingsStore!
    private var keychain: InMemoryKeychain!
    private var fake: FakeUSPSAPI!
    /// What the state's `now()` returns; tests move it forward.
    private var currentNow = HistoryRefreshTests.fixedNow

    private var availableDates: [Date] { PickupDateCalculator.availableDates(from: Self.fixedNow) }
    private var secondDay: String { PickupDateCalculator.apiDateString(availableDates[1]) }
    private var thirdDay: String { PickupDateCalculator.apiDateString(availableDates[2]) }

    override func setUp() {
        super.setUp()
        makeFixtures()
    }

    override func tearDown() {
        removeFixtures()
        super.tearDown()
    }

    private func makeFixtures() {
        suiteName = "PickupTests.\(UUID().uuidString)"
        settings = SettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        keychain = InMemoryKeychain()
        fake = FakeUSPSAPI()
        currentNow = Self.fixedNow
    }

    private func removeFixtures() {
        TestDefaults.remove(suiteName: suiteName)
        settings = nil
        suiteName = nil
    }

    // MARK: - Fixtures

    /// A configured user on the form, with `records` in the history.
    private func makeState(_ records: [PickupRecord]) -> AppState {
        try? keychain.saveCredentials(id: "key", secret: "secret")
        settings.address = address
        settings.contact = contact
        for record in records.reversed() { settings.addToHistory(record) }
        let fake = self.fake!
        let state = AppState(settings: settings, keychain: keychain,
                             apiFactory: { _ in fake }, notifier: SpyNotifier(),
                             now: { [unowned self] in self.currentNow })
        state.start()
        XCTAssertEqual(state.flow, .form)
        return state
    }

    /// Opens the history and waits for its background check to finish.
    private func open(_ state: AppState) async {
        state.showHistory()
        XCTAssertEqual(state.flow, .history)
        await state.historyRefreshTask?.value
    }

    private func reopen(_ state: AppState) async {
        state.closeHistory()
        await open(state)
    }

    private func record(_ number: String = "WTC1", date: String? = nil, etag: String? = "etag-1",
                        status: PickupRecord.Status = .scheduled) -> PickupRecord {
        var record = PickupRecord(confirmation: PickupConfirmation(confirmationNumber: number,
                                                                   pickupDate: date ?? secondDay),
                                  request: request(date: date ?? secondDay),
                                  createdAt: Self.fixedNow.addingTimeInterval(-3600))
        record.etag = etag
        record.status = status
        return record
    }

    /// What the app sent, and what an unchanged GET echoes back.
    private func request(date: String, weight: Double = 3, groundAdvantage: Int = 3,
                         instructions: String? = "By the gate", dogPresent: Bool = true,
                         location: PackageLocation = .porch) -> SchedulePickupRequest {
        SchedulePickupRequest(
            pickupDate: date,
            pickupAddress: PickupAddress(contact: contact, address: address),
            packages: [PackageLine(packageType: .groundAdvantage, packageCount: groundAdvantage),
                       PackageLine(packageType: .priorityMail, packageCount: 2)],
            estimatedWeight: weight,
            pickupLocation: PickupLocation(packageLocation: location, specialInstructions: instructions,
                                           dogPresent: dogPresent),
            nextAvailablePickup: false)
    }

    /// A GET, echoing every package type the way USPS does (zero counts
    /// included, in USPS's own order).
    private func fetched(_ number: String = "WTC1", date: String? = nil, etag: String = "etag-1",
                         weight: Double = 3, groundAdvantage: Int = 3,
                         instructions: String? = "By the gate", dogPresent: Bool = true,
                         location: PackageLocation = .porch) -> FetchedPickup {
        let date = date ?? secondDay
        var echoed = request(date: date, weight: weight, groundAdvantage: groundAdvantage,
                             instructions: instructions, dogPresent: dogPresent, location: location)
        echoed.packages = PackageType.allCases.map { type in
            PackageLine(packageType: type,
                        packageCount: type == .groundAdvantage ? groundAdvantage : (type == .priorityMail ? 2 : 0))
        }
        return FetchedPickup(confirmation: PickupConfirmation(confirmationNumber: number, pickupDate: date),
                             request: echoed, etag: etag)
    }

    private func stored(_ number: String = "WTC1") throws -> PickupRecord {
        try XCTUnwrap(settings.history.first { $0.confirmationNumber == number })
    }

    // MARK: - Refresh

    func testRefreshUpdatesAChangedRecordAndFlagsIt() async throws {
        let state = makeState([record()])
        fake.fetchResult = .success(fetched(date: thirdDay, etag: "etag-2", weight: 9, groundAdvantage: 1,
                                            instructions: "Garage", dogPresent: false, location: .sideDoor))

        await open(state)

        XCTAssertEqual(fake.fetchCallCount, 1)
        XCTAssertEqual(fake.lastFetchConfirmationNumber, "WTC1")
        let record = try stored()
        XCTAssertTrue(record.changedExternally)
        XCTAssertEqual(record.pickupDate, thirdDay)
        XCTAssertEqual(record.etag, "etag-2")
        XCTAssertEqual(record.estimatedWeight, 9)
        // USPS's lines, zero counts dropped.
        XCTAssertEqual(record.packages, [PackageLine(packageType: .groundAdvantage, packageCount: 1),
                                         PackageLine(packageType: .priorityMail, packageCount: 2)])
        XCTAssertEqual(record.totalPackages, 3)
        XCTAssertEqual(record.location, .sideDoor)
        XCTAssertEqual(record.specialInstructions, "Garage")
        XCTAssertEqual(record.dogPresent, false)
        XCTAssertNil(record.updatedAt, "a change on usps.com is not an in-app update")
        XCTAssertFalse(state.isCheckingHistory)
        XCTAssertFalse(state.historyCheckFailed)
    }

    func testEachComparedFieldFlagsOnItsOwn() async throws {
        let variants: [FetchedPickup] = [
            fetched(etag: "e2", weight: 4),
            fetched(etag: "e2", groundAdvantage: 4),
            fetched(etag: "e2", instructions: "Garage"),
            fetched(etag: "e2", dogPresent: false),
            fetched(etag: "e2", location: .frontDoor),
            fetched(date: thirdDay, etag: "e2")
        ]
        for (index, variant) in variants.enumerated() {
            // A fresh store and fake per variant (XCTest's own setUp made the first).
            if index > 0 { removeFixtures(); makeFixtures() }
            let state = makeState([record()])
            fake.fetchResult = .success(variant)
            await open(state)
            XCTAssertTrue(try stored().changedExternally, "variant \(index) should flag")
        }
    }

    func testAnIdenticalRecordIsNotFlagged() async throws {
        let state = makeState([record()])
        // Same fields; USPS's zero lines and order differ, and nil == "" for
        // instructions.
        fake.fetchResult = .success(fetched(etag: "etag-1"))

        await open(state)

        XCTAssertEqual(fake.fetchCallCount, 1)
        XCTAssertFalse(try stored().changedExternally)
        XCTAssertEqual(try stored().packages, record().packages, "an unchanged record keeps its own lines")
    }

    func testEmptyInstructionsEqualNone() async throws {
        var record = record()
        record.specialInstructions = nil
        let state = makeState([record])
        fake.fetchResult = .success(fetched(instructions: ""))
        await open(state)
        XCTAssertFalse(try stored().changedExternally)
    }

    func testARecordWithoutAnETagStoresItSilentlyWhenTheDateMatches() async throws {
        let state = makeState([record(etag: nil)])
        fake.fetchResult = .success(fetched(etag: "etag-first", weight: 7))

        await open(state)

        let record = try stored()
        XCTAssertFalse(record.changedExternally)
        XCTAssertEqual(record.etag, "etag-first")
        XCTAssertEqual(record.estimatedWeight, 7, "the fetched fields are stored too")
    }

    func testARecordWithoutAnETagIsNeverFlaggedEvenWhenTheDateDiffers() async throws {
        // First contact: the app has never seen USPS's copy, so it cannot
        // tell a change from USPS's own normalization. It adopts it silently.
        let state = makeState([record(etag: nil)])
        fake.fetchResult = .success(fetched(date: thirdDay, etag: "etag-first", weight: 9,
                                            instructions: "Garage", dogPresent: false))

        await open(state)

        let record = try stored()
        XCTAssertFalse(record.changedExternally)
        XCTAssertEqual(record.pickupDate, thirdDay, "USPS's copy is adopted")
        XCTAssertEqual(record.estimatedWeight, 9)
        XCTAssertEqual(record.etag, "etag-first")
        XCTAssertEqual(state.flaggedDuringCurrentPresentation, [])
    }

    func testARealChangeAfterFirstContactFlags() async throws {
        let state = makeState([record(etag: nil)])
        fake.fetchResult = .success(fetched(etag: "etag-first"))
        await open(state)
        XCTAssertFalse(try stored().changedExternally)

        currentNow = currentNow.addingTimeInterval(301)
        fake.fetchResult = .success(fetched(date: thirdDay, etag: "etag-second"))
        await reopen(state)
        XCTAssertTrue(try stored().changedExternally)
        XCTAssertEqual(try stored().pickupDate, thirdDay)
    }

    // MARK: - USPS's normalization is not a change

    func testUSPSNormalizationDoesNotFlag() async throws {
        // What the app sent, and what USPS sends back for it (seen live on
        // the test environment): the weight rounded up to a whole pound, the
        // instructions upper-cased, and no `dogPresent` key (decoded false).
        var sent = record()
        sent.estimatedWeight = 3.5
        sent.specialInstructions = "Behind the planter"
        sent.dogPresent = false
        let state = makeState([sent])
        fake.fetchResult = .success(fetched(etag: "etag-2", weight: 4,
                                            instructions: "BEHIND THE PLANTER ", dogPresent: false))

        await open(state)

        let record = try stored()
        XCTAssertFalse(record.changedExternally)
        XCTAssertEqual(record.estimatedWeight, 4, "USPS's copy is stored")
        XCTAssertEqual(record.specialInstructions, "BEHIND THE PLANTER ")
        XCTAssertEqual(record.etag, "etag-2")
    }

    func testWeightsCompareByTheWholePoundUSPSRoundsUpTo() {
        XCTAssertTrue(PickupRecord.sameWeight(3.5, 4))
        XCTAssertTrue(PickupRecord.sameWeight(2, 2))
        XCTAssertTrue(PickupRecord.sameWeight(0.2, 1))
        XCTAssertFalse(PickupRecord.sameWeight(2, 3.2))
        XCTAssertFalse(PickupRecord.sameWeight(3, 4))
        XCTAssertFalse(PickupRecord.sameWeight(4, 4.5))
    }

    func testInstructionsCompareTrimmedAndIgnoringCase() {
        XCTAssertTrue(PickupRecord.sameInstructions("Behind the planter", "BEHIND THE PLANTER"))
        XCTAssertTrue(PickupRecord.sameInstructions("  gate ", "GATE"))
        XCTAssertTrue(PickupRecord.sameInstructions(nil, ""))
        XCTAssertTrue(PickupRecord.sameInstructions(" ", nil))
        XCTAssertFalse(PickupRecord.sameInstructions("Gate", "Garage"))
        XCTAssertFalse(PickupRecord.sameInstructions(nil, "Gate"))
    }

    func testPastAndCancelledRecordsAreNeverFetched() async throws {
        let past = record("WTCPAST", date: "2026-09-10")
        let cancelled = record("WTCGONE", status: .cancelled)
        let state = makeState([past, cancelled, record("WTC1")])
        fake.fetchResult = .success(fetched(date: thirdDay, etag: "etag-2"))

        await open(state)

        XCTAssertEqual(fake.fetchCallCount, 1)
        XCTAssertEqual(fake.lastFetchConfirmationNumber, "WTC1")
        XCTAssertEqual(try stored("WTCPAST"), past)
        XCTAssertEqual(try stored("WTCGONE"), cancelled)
    }

    func testNothingToCheckShowsNoIndicator() async {
        let state = makeState([record("WTCPAST", date: "2026-09-10")])
        await open(state)
        XCTAssertEqual(fake.fetchCallCount, 0)
        XCTAssertFalse(state.isCheckingHistory)
        XCTAssertFalse(state.historyCheckFailed)
    }

    func testTheIndicatorShowsWhileChecking() async {
        let state = makeState([record()])
        state.showHistory()
        XCTAssertTrue(state.isCheckingHistory, "the list renders at once, with the check running")
        await state.historyRefreshTask?.value
        XCTAssertFalse(state.isCheckingHistory)
        XCTAssertNil(state.historyRefreshTask)
    }

    func testAFailingFetchLeavesTheRecordUntouchedAndStaysQuiet() async throws {
        let before = record()
        let state = makeState([before, record("WTC2")])
        fake.fetchResults = [.failure(USPSError.offline),
                             .success(fetched("WTC2", date: thirdDay, etag: "etag-2"))]

        await open(state)

        XCTAssertEqual(fake.fetchCallCount, 2)
        XCTAssertEqual(try stored("WTC1"), before)
        XCTAssertTrue(try stored("WTC2").changedExternally)
        XCTAssertEqual(state.flow, .history, "no error screen")
        XCTAssertFalse(state.historyCheckFailed, "only shown when every check failed")
    }

    func testEveryFetchFailingShowsTheQuietCaption() async throws {
        let before = record()
        let state = makeState([before])
        fake.fetchResult = .failure(USPSError.badRequest(message: "nope", details: []))

        await open(state)

        XCTAssertEqual(state.flow, .history)
        XCTAssertTrue(state.historyCheckFailed)
        XCTAssertEqual(try stored(), before)

        // The next presentation starts without it.
        currentNow = currentNow.addingTimeInterval(301)
        fake.fetchResult = .success(fetched())
        state.closeHistory()
        state.showHistory()
        XCTAssertFalse(state.historyCheckFailed)
        await state.historyRefreshTask?.value
        XCTAssertFalse(state.historyCheckFailed)
    }

    func testRejectedCredentialsDuringTheCheckStayQuiet() async {
        let state = makeState([record()])
        fake.fetchResult = .failure(USPSError.invalidCredentials)
        await open(state)
        XCTAssertEqual(state.flow, .history)
        XCTAssertTrue(state.historyCheckFailed)
    }

    func testTheCheckIsThrottledForFiveMinutes() async {
        let state = makeState([record()])
        await open(state)
        XCTAssertEqual(fake.fetchCallCount, 1)
        XCTAssertEqual(state.lastHistoryRefresh, Self.fixedNow)

        currentNow = Self.fixedNow.addingTimeInterval(4 * 60 + 59)
        await reopen(state)
        XCTAssertEqual(fake.fetchCallCount, 1, "within 5 minutes of the last check")
        XCTAssertFalse(state.isCheckingHistory)

        currentNow = Self.fixedNow.addingTimeInterval(5 * 60 + 1)
        await reopen(state)
        XCTAssertEqual(fake.fetchCallCount, 2)
    }

    // MARK: - Refresh button

    func testAManualRefreshIgnoresTheFiveMinuteWindow() async throws {
        let state = makeState([record()])
        await open(state)
        XCTAssertEqual(fake.fetchCallCount, 1)

        currentNow = Self.fixedNow.addingTimeInterval(20)
        fake.fetchResult = .success(fetched(date: thirdDay, etag: "etag-2"))
        state.refreshHistory(manual: true)
        XCTAssertTrue(state.isCheckingHistory)
        await state.historyRefreshTask?.value

        XCTAssertEqual(fake.fetchCallCount, 2)
        XCTAssertTrue(try stored().changedExternally)
        XCTAssertEqual(state.lastManualRefreshAttempt, currentNow)
        XCTAssertEqual(state.lastHistoryRefresh, currentNow)
    }

    func testAManualRefreshWhileOneIsRunningIsIgnored() async {
        let state = makeState([record()])
        state.showHistory()
        XCTAssertNotNil(state.historyRefreshTask)
        state.refreshHistory(manual: true)
        XCTAssertNil(state.lastManualRefreshAttempt, "an ignored press does not count")
        await state.historyRefreshTask?.value
        XCTAssertEqual(fake.fetchCallCount, 1)
    }

    func testManualRefreshesAreLimitedToOnePerTenSeconds() async {
        let state = makeState([record()])
        await open(state)
        XCTAssertEqual(fake.fetchCallCount, 1)

        state.refreshHistory(manual: true)
        await state.historyRefreshTask?.value
        XCTAssertEqual(fake.fetchCallCount, 2)

        currentNow = Self.fixedNow.addingTimeInterval(9)
        state.refreshHistory(manual: true)
        XCTAssertNil(state.historyRefreshTask, "dropped inside the 10 s window")
        XCTAssertEqual(fake.fetchCallCount, 2)

        currentNow = Self.fixedNow.addingTimeInterval(11)
        state.refreshHistory(manual: true)
        await state.historyRefreshTask?.value
        XCTAssertEqual(fake.fetchCallCount, 3)
    }

    func testAManualRefreshWithNothingUpcomingDoesNothing() async {
        let state = makeState([record("WTCPAST", date: "2026-09-10")])
        await open(state)
        state.refreshHistory(manual: true)
        XCTAssertNil(state.historyRefreshTask)
        XCTAssertFalse(state.isCheckingHistory)
        XCTAssertEqual(fake.fetchCallCount, 0)
    }

    func testARecordChangedInTheAppMeanwhileIsNotOverwritten() async throws {
        let state = makeState([record()])
        fake.fetchResult = .success(fetched(date: thirdDay, etag: "etag-2"))
        state.showHistory()
        // Before the check gets to it, the record changes locally.
        var local = try stored()
        local.estimatedWeight = 12
        settings.updateHistory(local)
        await state.historyRefreshTask?.value
        XCTAssertEqual(try stored(), local)
    }

    // MARK: - Clearing the dot

    func testTheDotClearsTheNextTimeTheListIsShown() async throws {
        let state = makeState([record()])
        fake.fetchResult = .success(fetched(date: thirdDay, etag: "etag-2"))
        await open(state)
        XCTAssertTrue(try stored().changedExternally)
        XCTAssertEqual(state.flaggedDuringCurrentPresentation, ["WTC1"])

        // Throttled: no new check, and the dot from the last presentation goes.
        await reopen(state)
        XCTAssertEqual(fake.fetchCallCount, 1)
        XCTAssertFalse(try stored().changedExternally)
        XCTAssertEqual(state.flaggedDuringCurrentPresentation, [])
    }

    func testANewChangeFlagsAgainOnTheNextPresentation() async throws {
        let state = makeState([record()])
        fake.fetchResult = .success(fetched(date: thirdDay, etag: "etag-2"))
        await open(state)
        currentNow = currentNow.addingTimeInterval(301)
        fake.fetchResult = .success(fetched(date: thirdDay, etag: "etag-3", weight: 8))
        await reopen(state)
        XCTAssertTrue(try stored().changedExternally)
        XCTAssertEqual(try stored().estimatedWeight, 8)

        // Unchanged since: the dot goes on the presentation after.
        currentNow = currentNow.addingTimeInterval(301)
        await reopen(state)
        XCTAssertFalse(try stored().changedExternally)
    }

    func testTheDotClearsWhenThePickupIsModifiedInTheApp() async throws {
        let state = makeState([record()])
        fake.fetchResult = .success(fetched(date: thirdDay, etag: "etag-2"))
        await open(state)
        XCTAssertTrue(try stored().changedExternally)

        await state.beginModify(try stored())
        XCTAssertEqual(state.flow, .modifying(confirmationNumber: "WTC1"))
        state.draft.hazmatConfirmed = true
        fake.updateResult = .success(fetched(date: thirdDay, etag: "etag-after-put"))
        await state.saveModification()

        let record = try stored()
        XCTAssertFalse(record.changedExternally)
        XCTAssertEqual(record.etag, "etag-after-put", "the PUT's ETag is kept")
    }

    func testTheDotClearsWhenThePickupIsCancelled() async throws {
        let state = makeState([record()])
        fake.fetchResult = .success(fetched(date: thirdDay, etag: "etag-2"))
        await open(state)
        await state.cancelPickup(try stored())
        XCTAssertEqual(try stored().status, .cancelled)
        XCTAssertFalse(try stored().changedExternally)
    }

    func testBeginModifyStoresTheFetchedETag() async throws {
        let state = makeState([record(etag: nil)])
        fake.fetchResult = .failure(USPSError.offline)
        await open(state)
        XCTAssertNil(try stored().etag)

        fake.fetchResult = .success(fetched(etag: "etag-modify"))
        await state.beginModify(try stored())
        XCTAssertEqual(try stored().etag, "etag-modify")
        XCTAssertFalse(try stored().changedExternally)
    }

    func testScheduleStoresNoETag() async throws {
        let state = makeState([])
        state.draft.counts[.priorityMail] = 1
        state.draft.hazmatConfirmed = true
        await state.schedule()
        let record = try XCTUnwrap(settings.history.first)
        XCTAssertNil(record.etag)
        XCTAssertFalse(record.changedExternally)
    }

    /// The POST response's `carrierPickupRequest` as the test environment
    /// sends it back for a draft of 3.5 lb, "Behind the planter", no dog.
    private func uspsEcho(of sent: SchedulePickupRequest) -> SchedulePickupRequest {
        var echo = sent
        echo.estimatedWeight = 4
        echo.pickupLocation = PickupLocation(packageLocation: sent.pickupLocation.packageLocation,
                                             specialInstructions: "BEHIND THE PLANTER",
                                             dogPresent: false)
        echo.pickupAddress.firstName = "TODD"
        echo.pickupAddress.address.streetAddress = "4120 BINGHAM AVE"
        echo.pickupAddress.address.city = "SAINT LOUIS"
        echo.packages = PackageType.allCases.map { type in
            PackageLine(packageType: type, packageCount: type == .priorityMail ? 1 : 0)
        }
        echo.nextAvailablePickup = false
        return echo
    }

    private func scheduleNormalizedPickup() async throws -> AppState {
        let state = makeState([])
        state.draft.counts = [.priorityMail: 1]
        state.draft.hazmatConfirmed = true
        state.draft.weight = 3.5
        state.draft.instructions = "Behind the planter"
        state.draft.dogPresent = false
        let sent = state.draft.request(address: address, contact: contact)
        fake.scheduleResult = .success(PickupConfirmation(confirmationNumber: "WTC9",
                                                          pickupDate: secondDay,
                                                          request: uspsEcho(of: sent)))
        await state.schedule()
        XCTAssertEqual(state.flow, .confirmed(PickupConfirmation(confirmationNumber: "WTC9",
                                                                 pickupDate: secondDay)),
                       "the screen gets the bare confirmation")
        return state
    }

    func testScheduleStoresUSPSsCopyFromThePOSTResponse() async throws {
        _ = try await scheduleNormalizedPickup()
        XCTAssertEqual(fake.lastScheduleRequest?.estimatedWeight, 3.5, "the draft is what was sent")
        let record = try stored("WTC9")
        XCTAssertEqual(record.estimatedWeight, 4)
        XCTAssertEqual(record.specialInstructions, "BEHIND THE PLANTER")
        XCTAssertEqual(record.dogPresent, false)
        XCTAssertEqual(record.packages, [PackageLine(packageType: .priorityMail, packageCount: 1)])
        XCTAssertEqual(record.totalPackages, 1)
        XCTAssertEqual(record.addressLine, "4120 BINGHAM AVE, SAINT LOUIS MO")
        XCTAssertEqual(record.pickupDate, secondDay)
        XCTAssertNil(record.etag)
        XCTAssertNil(settings.lastConfirmation?.request, "the echo is not kept with the confirmation")
    }

    func testScheduleKeepsTheTopLevelDateOverTheEchoedOne() async throws {
        let state = makeState([])
        state.draft.counts = [.priorityMail: 1]
        state.draft.hazmatConfirmed = true
        var echo = state.draft.request(address: address, contact: contact)
        echo.pickupDate = "2000-01-01"
        fake.scheduleResult = .success(PickupConfirmation(confirmationNumber: "WTC9",
                                                          pickupDate: thirdDay, request: echo))
        await state.schedule()
        XCTAssertEqual(try stored("WTC9").pickupDate, thirdDay)
    }

    func testANewlyScheduledPickupGetsNoDotFromUSPSsOwnCopy() async throws {
        let state = try await scheduleNormalizedPickup()
        // The GET returns the same normalized copy, without `dogPresent`.
        let sent = try XCTUnwrap(fake.lastScheduleRequest)
        fake.fetchResult = .success(FetchedPickup(
            confirmation: PickupConfirmation(confirmationNumber: "WTC9", pickupDate: secondDay),
            request: uspsEcho(of: sent), etag: "etag-get"))

        await open(state)
        XCTAssertEqual(fake.fetchCallCount, 1)
        XCTAssertFalse(try stored("WTC9").changedExternally)
        XCTAssertEqual(try stored("WTC9").etag, "etag-get")

        // Checked again later, still the same: still no dot.
        currentNow = currentNow.addingTimeInterval(301)
        await reopen(state)
        XCTAssertEqual(fake.fetchCallCount, 2)
        XCTAssertFalse(try stored("WTC9").changedExternally)
    }

    func testARecordHoldingTheDraftIsNotFlaggedByUSPSsCopy() async throws {
        // A record stored before USPS's copy was kept, already checked once
        // (so it has an ETag): the draft's 3.5 lb against USPS's 4 is the
        // same pickup.
        var old = record()
        old.estimatedWeight = 3.5
        old.specialInstructions = "Behind the planter"
        old.dogPresent = false
        let state = makeState([old])
        fake.fetchResult = .success(fetched(etag: "etag-2", weight: 4,
                                            instructions: "BEHIND THE PLANTER", dogPresent: false))
        await open(state)
        XCTAssertFalse(try stored().changedExternally)
    }

    func testSaveModificationStoresUSPSsCopyFromThePUTResponse() async throws {
        let state = makeState([record()])
        await open(state)
        fake.fetchResult = .success(fetched(etag: "etag-1"))
        await state.beginModify(try stored())
        XCTAssertEqual(state.flow, .modifying(confirmationNumber: "WTC1"))
        state.draft.hazmatConfirmed = true
        state.draft.weight = 3.5
        state.draft.instructions = "Behind the planter"
        fake.updateResult = .success(fetched(etag: "etag-put", weight: 4,
                                             instructions: "BEHIND THE PLANTER", dogPresent: false))
        await state.saveModification()

        let record = try stored()
        XCTAssertEqual(fake.lastUpdate?.request.estimatedWeight, 3.5)
        XCTAssertEqual(record.estimatedWeight, 4)
        XCTAssertEqual(record.specialInstructions, "BEHIND THE PLANTER")
        XCTAssertEqual(record.dogPresent, false)
        XCTAssertEqual(record.etag, "etag-put")
        XCTAssertNotNil(record.updatedAt)
        XCTAssertFalse(record.changedExternally)
    }

    // MARK: - Persistence

    func testTheFlagAndETagSurviveAReload() async throws {
        let state = makeState([record()])
        fake.fetchResult = .success(fetched(date: thirdDay, etag: "etag-2"))
        await open(state)

        let reloaded = SettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let record = try XCTUnwrap(reloaded.history.first)
        XCTAssertTrue(record.changedExternally)
        XCTAssertEqual(record.etag, "etag-2")
        XCTAssertEqual(record.specialInstructions, "By the gate")
        XCTAssertEqual(record.dogPresent, true)
    }

    func testAPersistedFlagClearsTheFirstTimeTheListOpensAfterRelaunch() async throws {
        var flagged = record()
        flagged.changedExternally = true
        let state = makeState([flagged])
        fake.fetchResult = .success(fetched())
        await open(state)
        XCTAssertFalse(try stored().changedExternally)
    }

    func testAnOldSnapshotWithoutTheNewFieldsDecodes() throws {
        let json = #"""
        {"defaultLocation":"PORCH","defaultInstructions":"","dogPresent":false,"defaultWeight":1,
         "useTestEnvironment":false,
         "history":[{"confirmationNumber":"WTC5","pickupDate":"2026-10-03","createdAt":0,
                     "packages":[{"packageType":"PRIORITY_MAIL","packageCount":1}],"totalPackages":1,
                     "estimatedWeight":2,"location":"PORCH","addressLine":"1 MAIN ST, X TX",
                     "status":"scheduled"}]}
        """#
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(Data(json.utf8), forKey: "settings.v1")

        let store = SettingsStore(defaults: defaults)
        let record = try XCTUnwrap(store.history.first)
        XCTAssertEqual(record.confirmationNumber, "WTC5")
        XCTAssertFalse(record.changedExternally)
        XCTAssertNil(record.etag)
        XCTAssertNil(record.specialInstructions)
        XCTAssertNil(record.dogPresent)
    }
}
