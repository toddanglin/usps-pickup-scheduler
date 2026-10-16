# PickupBar v1 Implementation Plan

> **Historical.** This plan was written and executed when the app was called
> PickupBar. It was renamed to **Pickup** in 1.0.1 (directories `Pickup/`,
> `PickupTests/`, `PickupUITests/`; bundle id `com.toddanglin.Pickup`); the
> names below are as they were at the time. The current state is in the spec.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a native macOS menu bar app that schedules a USPS Carrier Pickup via the USPS v3 API using user-supplied Consumer Key/Secret.

**Architecture:** SwiftUI `MenuBarExtra` app driven by a `@MainActor AppState` state machine; pure-Swift service layer (`LiveUSPSClient`, `TokenManager`, `KeychainStore`, `SettingsStore`, `PickupDateCalculator`) that is unit-tested with a `URLProtocol` mock and fakes. Views are thin and switch on `FlowState`.

**Tech Stack:** Swift 5 language mode on Swift 6.3 toolchain, SwiftUI, macOS 14+, XcodeGen, XCTest, Python stdlib mock server for manual QA.

**The spec is the contract:** `docs/superpowers/specs/2026-09-18-pickupbar-design.md`. All type names, cases, raw values, and copy strings come from it. Read it before starting any task.

**Build/test commands (all tasks):**
```bash
make generate   # xcodegen generate
make build      # xcodebuild -project PickupBar.xcodeproj -scheme PickupBar -configuration Debug -derivedDataPath .build/dd build
make test       # xcodebuild ... -scheme PickupBar -destination 'platform=macOS' -derivedDataPath .build/dd test
```
When several agents run concurrently, each passes its own `DD=.build/<task>` (Makefile honors `DD`).

---

### Task 1: Project scaffold

**Files:**
- Create: `project.yml`, `Makefile`, `.gitignore`, `LICENSE` (MIT, © 2026 Todd Anglin), `README.md` (title + one-paragraph placeholder)
- Create: `PickupBar/App/PickupBarApp.swift`, `PickupBar/Info.plist`, `PickupBar/PickupBar.entitlements`, `PickupBar/Resources/Assets.xcassets/Contents.json`, `PickupBar/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json` (empty set for now)
- Create: `PickupBarTests/SmokeTests.swift`

- [ ] **Step 1: project.yml**

```yaml
name: PickupBar
options:
  bundleIdPrefix: com.toddanglin
  deploymentTarget:
    macOS: "14.0"
  xcodeVersion: "26.0"
  createIntermediateGroups: true
settings:
  base:
    SWIFT_VERSION: "5.0"
    MARKETING_VERSION: "1.0.0"
    CURRENT_PROJECT_VERSION: "1"
    CODE_SIGN_STYLE: Automatic
    CODE_SIGN_IDENTITY: "-"
    ENABLE_HARDENED_RUNTIME: YES
targets:
  PickupBar:
    type: application
    platform: macOS
    sources:
      - path: PickupBar
        excludes: ["Info.plist"]
    info:
      path: PickupBar/Info.plist
      properties:
        CFBundleDisplayName: PickupBar
        CFBundleName: PickupBar
        LSUIElement: true
        LSMinimumSystemVersion: "14.0"
        NSHumanReadableCopyright: "© 2026 Todd Anglin. MIT License."
        NSAppTransportSecurity:
          NSAllowsLocalNetworking: true
    entitlements:
      path: PickupBar/PickupBar.entitlements
      properties:
        com.apple.security.app-sandbox: true
        com.apple.security.network.client: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.toddanglin.PickupBar
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        SWIFT_STRICT_CONCURRENCY: minimal
  PickupBarTests:
    type: bundle.unit-test
    platform: macOS
    sources: [PickupBarTests]
    dependencies:
      - target: PickupBar
    settings:
      base:
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/PickupBar.app/Contents/MacOS/PickupBar"
        BUNDLE_LOADER: "$(TEST_HOST)"
schemes:
  PickupBar:
    build:
      targets: { PickupBar: all, PickupBarTests: [test] }
    run:
      config: Debug
    test:
      config: Debug
      targets: [PickupBarTests]
```

- [ ] **Step 2: Makefile**

```make
DD ?= .build/dd
PROJ = PickupBar.xcodeproj
XCB = xcodebuild -project $(PROJ) -scheme PickupBar -derivedDataPath $(DD) -quiet

.PHONY: generate build test run clean icon
generate:
	xcodegen generate
build: generate
	$(XCB) -configuration Debug build
release: generate
	$(XCB) -configuration Release build
	@echo "App at $(DD)/Build/Products/Release/PickupBar.app"
test: generate
	$(XCB) -destination 'platform=macOS' test
run: build
	open $(DD)/Build/Products/Debug/PickupBar.app
icon:
	swift Scripts/make-icon.swift PickupBar/Resources/Assets.xcassets/AppIcon.appiconset
clean:
	rm -rf .build $(PROJ)
```

- [ ] **Step 3: .gitignore** — `.build/`, `*.xcodeproj/`, `xcuserdata/`, `.DS_Store`, `DerivedData/`.

- [ ] **Step 4: PickupBarApp.swift (placeholder body)**

```swift
import SwiftUI

@main
struct PickupBarApp: App {
    var body: some Scene {
        MenuBarExtra {
            Text("PickupBar").padding()
        } label: {
            Image(systemName: "envelope")
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 5: SmokeTests.swift** — `XCTAssertTrue(true)` so the test target links.

- [ ] **Step 6: Run** `make test` → BUILD SUCCEEDED, 1 test passed. Also `make build` and confirm `.build/dd/Build/Products/Debug/PickupBar.app` exists.

---

### Task 2: Models and wire encoding

**Files:**
- Create: `PickupBar/Models/PackageType.swift`, `PackageLocation.swift`, `Address.swift` (PostalAddress, PickupContact, ContactEntry, PickupAddress), `Pickup.swift` (PackageLine, PickupLocation, SchedulePickupRequest, PickupConfirmation, USPSErrorBody)
- Test: `PickupBarTests/ModelEncodingTests.swift`

- [ ] **Step 1: Tests** (write first; they fail to compile until models exist)

```swift
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

    func testDisplayNames() {
        XCTAssertEqual(PackageType.groundAdvantage.displayName, "Ground Advantage")
        XCTAssertEqual(PackageLocation.knockOnDoor.displayName, "Knock on Door / Ring Bell")
    }
}
```

- [ ] **Step 2: Implement** per spec §4.2. `ContactEntry` is `enum ContactEntry: Codable, Equatable { case email(String?); case phone(String?) }` with custom coding: encode `{"email": x}` / `{"phone": x}`; decode accepts keys `email` or `eMail` (USPS eligibility response uses `eMail`) and `phone`. `PackageLine.packageCount` decodes Int or String. `PickupConfirmation` decodes only `confirmationNumber` and `pickupDate` from the top level.
- [ ] **Step 3:** `make test` passes.

---

### Task 3: PickupDateCalculator

**Files:**
- Create: `PickupBar/Services/PickupDateCalculator.swift`
- Test: `PickupBarTests/PickupDateCalculatorTests.swift`

- [ ] **Step 1: Tests**

```swift
import XCTest
@testable import PickupBar

final class PickupDateCalculatorTests: XCTestCase {
    let chicago = TimeZone(identifier: "America/Chicago")!
    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = chicago
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    func days(_ dates: [Date]) -> [String] { dates.map(PickupDateCalculator.apiDateString) }

    func testBeforeTwoAMIncludesToday() {
        // Thu 2026-09-17 01:30 CT
        XCTAssertEqual(days(PickupDateCalculator.availableDates(from: date(2026,9,17,1,30), count: 2)), ["2026-09-17", "2026-09-18"])
    }
    func testAfterTwoAMStartsTomorrow() {
        XCTAssertEqual(days(PickupDateCalculator.availableDates(from: date(2026,9,17,2,0), count: 1)), ["2026-09-18"])
    }
    func testSkipsSunday() {
        // Sat 2026-09-19 noon → Mon 21
        XCTAssertEqual(days(PickupDateCalculator.availableDates(from: date(2026,9,19), count: 2)), ["2026-09-21", "2026-09-22"])
    }
    func testSkipsThanksgivingAndObservedChristmas() {
        // Wed 2026-11-25 → Fri 27 (Thu 26 is Thanksgiving)
        XCTAssertEqual(days(PickupDateCalculator.availableDates(from: date(2026,11,25), count: 1)), ["2026-11-27"])
        // 2027-12-25 is a Saturday → observed Fri 24. From Thu 2027-12-23 noon → Mon 27.
        XCTAssertEqual(days(PickupDateCalculator.availableDates(from: date(2027,12,23), count: 1)), ["2027-12-27"])
    }
    func testObservedMondayWhenHolidayOnSunday() {
        // 2027-07-04 is Sunday → observed Mon Jul 5. From Sat Jul 3 noon → Tue Jul 6.
        XCTAssertEqual(days(PickupDateCalculator.availableDates(from: date(2027,7,3), count: 1)), ["2027-07-06"])
    }
    func testReturnsRequestedCount() {
        XCTAssertEqual(PickupDateCalculator.availableDates(from: date(2026,9,17), count: 6).count, 6)
    }
}
```

- [ ] **Step 2: Implement** per spec §4.4 (holiday table with `isHoliday(_:)`, observed shifting, loop until `count` collected, cap 60 iterations). Provide `static func displayLabel(_ date: Date) -> (weekday: String, day: String)` e.g. ("Fri", "19") for chips, and `static func longDisplay(_ date: Date) -> String` ("Friday, September 19, 2026").
- [ ] **Step 3:** `make test` passes.

---

### Task 4: USPSError + LiveUSPSClient + TokenManager

**Files:**
- Create: `PickupBar/Services/USPSError.swift`, `PickupBar/Services/USPSAPI.swift` (protocol + OAuthToken), `PickupBar/Services/LiveUSPSClient.swift`, `PickupBar/Services/TokenManager.swift`, `PickupBar/Services/BaseURL.swift`
- Test: `PickupBarTests/MockURLProtocol.swift`, `PickupBarTests/LiveUSPSClientTests.swift`, `PickupBarTests/TokenManagerTests.swift`

- [ ] **Step 1: MockURLProtocol**

```swift
import Foundation
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { fatalError("no handler") }
        do {
            let (resp, data) = try handler(request)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [MockURLProtocol.self]; return URLSession(configuration: c)
    }
}
```
Note: `URLRequest.httpBody` is nil inside a URLProtocol; read `httpBodyStream` to inspect bodies (helper `bodyData(of:)`).

- [ ] **Step 2: LiveUSPSClientTests** — cases (each sets `MockURLProtocol.handler`, builds `LiveUSPSClient(baseURL: URL(string:"https://apis.usps.com")!, session: MockURLProtocol.session())`):
  - `fetchToken` posts JSON `{grant_type:"client_credentials",client_id,client_secret}` to `/oauth2/v3/token`, parses `access_token` + `expires_in` (as Int **or String** — USPS README shows strings) → `expiresAt ≈ now + expires_in`.
  - token 401 → `USPSError.invalidCredentials`; token 400 with body `{"error":"invalid_client"}` → `.invalidCredentials`.
  - `checkEligibility` builds query `streetAddress, secondaryAddress?, city, state, ZIPCode` and decodes standardized `address` from `{"pickupAddress":{"address":{...}}}` **or** top-level `{"address":{...}}`; 400 → `.addressNotEligible(message)` using `error.message` from body when present else "Address not eligible".
  - `schedulePickup` posts to `/pickup/v3/carrier-pickup` with `Authorization: Bearer`, `Accept: application/json`, decodes `PickupConfirmation`.
  - schedule 403 → `.forbidden`; 429 → `.rateLimited`; 503 → `.serviceUnavailable`; 400 with `{"error":{"message":"Bad date","errors":[{"message":"pickupDate must be future"}]}}` → `.badRequest(message:"Bad date", details:["pickupDate must be future"])`; 500 → `.unexpected(status:500, body:)`; `URLError(.notConnectedToInternet)` → `.offline`.
- [ ] **Step 3: Implement** `USPSError` (spec §4.3 incl. copy), `USPSAPI`, `LiveUSPSClient` (single `send` helper doing status mapping), `BaseURL.resolve(useTestEnvironment:) -> URL` (env var `PICKUPBAR_BASE_URL` > TEM `https://apis-tem.usps.com` > `https://apis.usps.com`).
- [ ] **Step 4: TokenManagerTests** with a `FakeUSPSAPI` (class with counters, controllable `tokenResult`): first call fetches; second call within expiry returns cached without fetch; token expiring in 30 s triggers refetch; `invalidate()` forces refetch; missing credentials throws `.invalidCredentials`.
- [ ] **Step 5:** `make test` passes.

---

### Task 5: KeychainStore + SettingsStore

**Files:**
- Create: `PickupBar/Services/KeychainStore.swift`, `PickupBar/Services/SettingsStore.swift`
- Test: `PickupBarTests/SettingsStoreTests.swift`

- [ ] **Step 1: SettingsStoreTests** — init with `UserDefaults(suiteName: "test.\(UUID())")`; defaults match spec; mutate `defaultLocation = .mailbox` and `address`; new instance on same suite reads back; `clear()` resets.
- [ ] **Step 2: Implement** `SettingsStore` (`@Published` props with `didSet { persist() }` guarded by an `isLoading` flag; single Codable `Snapshot` struct persisted under `settings.v1`). Add `var isAddressConfigured: Bool { address != nil && contact != nil }`.
- [ ] **Step 3: Implement** `KeychainStore` with `SecItemAdd/Copy/Update/Delete`, generic password, `kSecAttrService = "com.toddanglin.PickupBar"`, accounts `usps-consumer-key` / `usps-consumer-secret`, `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlock`. Wrap OSStatus errors in `KeychainError.osStatus(Int32)`. Keychain is not unit-tested (needs entitlement/interactive); keep it tiny.
- [ ] **Step 4:** `make test` passes.

---

### Task 6: AppState

**Files:**
- Create: `PickupBar/App/AppState.swift`, `PickupBar/App/FlowState.swift`, `PickupBar/App/PickupDraft.swift`
- Test: `PickupBarTests/AppStateTests.swift`

- [ ] **Step 1: Define**

```swift
struct PickupDraft: Equatable {
    var selectedDate: Date
    var location: PackageLocation
    var instructions: String
    var dogPresent: Bool
    var counts: [PackageType: Int]     // all six keys present
    var weight: Double
    var hazmatConfirmed: Bool = false
    var totalPackages: Int { counts.values.reduce(0, +) }
    var canSubmit: Bool { totalPackages > 0 && weight > 0 && hazmatConfirmed }
    static func fromDefaults(_ s: SettingsStore, now: Date = Date()) -> PickupDraft
    func request(address: PostalAddress, contact: PickupContact) -> SchedulePickupRequest
}

@MainActor final class AppState: ObservableObject {
    @Published private(set) var flow: FlowState
    @Published var draft: PickupDraft
    @Published private(set) var needsAttention = false
    @Published private(set) var credentialsStatus: CredentialsStatus = .unknown  // .unknown, .valid(Date), .invalid, .missing
    let settings: SettingsStore
    init(settings: SettingsStore, keychain: KeychainStoring, apiFactory: @escaping (URL) -> USPSAPI, notifier: Notifying, now: @escaping () -> Date = Date.init)
    func start()                                    // decides initial flow; kicks off background credential check
    func saveCredentials(id: String, secret: String) async throws   // verifies token first
    func removeCredentials()
    func validateAndSaveAddress(contact: PickupContact, address: PostalAddress) async throws -> PostalAddress
    func schedule() async
    func scheduleAnother()
    func retry()
    func openSettings()                             // NSApp.sendAction(Selector(("showSettingsWindow:")))… use SettingsLink where possible
    var api: USPSAPI                                // rebuilt when settings.useTestEnvironment changes
}
protocol KeychainStoring { func loadCredentials() throws -> (id: String, secret: String)?; func saveCredentials(id: String, secret: String) throws; func deleteCredentials() throws }
protocol Notifying { func notifyCredentialsNeeded() }
```

- [ ] **Step 2: AppStateTests** using `InMemoryKeychain`, `FakeUSPSAPI`, `SpyNotifier`: initial flow for each precondition; saveCredentials success/failure; schedule success → `.confirmed` and `settings.lastConfirmation` set; schedule with `.invalidCredentials` → `.needsCredentials`, `needsAttention == true`, notifier called once; schedule with `.rateLimited` → `.failed(_, retryable: true)`; retry → `.form` with draft unchanged; scheduleAnother → fresh draft from defaults.
- [ ] **Step 3: Implement**; `make test` passes.

---

### Task 7: Views + app wiring

**Files:**
- Modify: `PickupBar/App/PickupBarApp.swift`
- Create: `PickupBar/Views/RootView.swift`, `OnboardingView.swift`, `AddressFormView.swift` (shared by setup + settings), `AddressSetupView.swift`, `PickupFormView.swift`, `SchedulingView.swift`, `ConfirmationView.swift`, `ErrorView.swift`, `SettingsView.swift`, `Components/DayChips.swift`, `Components/PackageRow.swift`, `Components/FooterBar.swift`, `Components/PrimaryButton.swift`, `App/Notifier.swift` (UNUserNotificationCenter impl), `App/LaunchAtLogin.swift` (SMAppService)

- [ ] **Step 1:** `PickupBarApp` creates `SettingsStore`, `KeychainStore`, `AppState` as `@StateObject`; `MenuBarExtra` label = `Image(systemName: state.needsAttention ? "envelope.badge" : "envelope")`; content `RootView().environmentObject(state)`, `.frame(width: 340)`; add `Settings { SettingsView() }` scene. Call `state.start()` in `RootView.onAppear` (once).
- [ ] **Step 2:** Implement views per spec §4.5. Style rules: 16 pt padding, `GroupBox`-free custom cards using `RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5))`, headline `.font(.headline)`, secondary text `.foregroundStyle(.secondary)`, primary button `.buttonStyle(.borderedProminent).controlSize(.large)` full width, SF Symbols everywhere. Footer: `SettingsLink` gear (macOS 14) + "Quit" (`NSApp.terminate`). Day chips: `ScrollView(.horizontal)` of capsules, selected = accent fill. Scheduling view: envelope symbol with `.symbolEffect(.pulse)` + `ProgressView()`.
- [ ] **Step 3:** `make build` succeeds; `make run` shows the envelope in the menu bar and the onboarding screen.

---

### Task 8: App icon

**Files:**
- Create: `Scripts/make-icon.swift`; regenerate `PickupBar/Resources/Assets.xcassets/AppIcon.appiconset/*` (10 PNGs + Contents.json)

- [ ] **Step 1:** Script (AppKit, run via `swift Scripts/make-icon.swift <appiconset dir>`): draws a 1024×1024 image: transparent margin (icon occupies 824 pt centered, matching Apple's macOS icon grid), rounded rect (corner ≈ 185) with vertical linear gradient `#3A8DFF → #0A5BD8`, subtle inner top highlight, white `envelope.fill` SF Symbol rendered via `NSImage(systemSymbolName:)` + `NSImage.SymbolConfiguration(pointSize: 520, weight: .medium)` centered, soft drop shadow. Writes `icon_16x16.png … icon_512x512@2x.png` and `Contents.json` for the standard macOS set.
- [ ] **Step 2:** `make icon && make build`; verify with `sips -g pixelWidth` and open the app to see the icon in Finder/Activity Monitor.

---

### Task 9: Mock server + README

**Files:**
- Create: `Scripts/mock-server.py`, finish `README.md`

- [ ] **Step 1:** Python 3 stdlib `http.server` on port 8787: `POST /oauth2/v3/token` → `{access_token:"mock", token_type:"Bearer", expires_in:28799}` (401 if client_id == "bad"); `GET /pickup/v3/carrier-pickup/eligibility` → standardized (uppercased) address (400 with USPS error body if ZIPCode == "00000"); `POST /pickup/v3/carrier-pickup` → `{confirmationNumber:"WTC" + 9 random digits, pickupDate: request.pickupDate}` after 1.5 s delay; env `MOCK_FAIL=403|429|503|400` forces that status for schedule. Logs bodies.
- [ ] **Step 2:** README: what it is, screenshots placeholder, requirements (macOS 14, Xcode, XcodeGen via Homebrew), USPS setup (create account at developers.usps.com → Add App → copy Consumer Key/Secret; note about Carrier Pickup product/403), build & run, testing with the mock server, how errors are surfaced, privacy (keys in Keychain, no telemetry), license.

---

### Task 10: Verification pass (orchestrator)

- [ ] `make test` green; `make release` builds.
- [ ] Run against mock server; walk onboarding → address → form → scheduling → confirmation → schedule another; force each `MOCK_FAIL` and check ErrorView copy; set `MOCK_FAIL` token 401 path to see badge + notification.
- [ ] Code review of the whole tree against spec (subagent), fix findings, final commit.
