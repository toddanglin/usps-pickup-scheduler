import XCTest

/// End-to-end walk of the real PickupBar app against `Scripts/mock-server.py`.
///
/// The app is a `MenuBarExtra` (LSUIElement), so there is no ordinary window to
/// drive: the test clicks the status item to open the popover and then walks the
/// whole happy path, screenshotting every screen. Screenshots are attached to
/// the result bundle *and* written to disk (see `screenshotDirectories`) so they
/// can be inspected without opening the .xcresult.
final class PickupBarUITests: XCTestCase {

    /// Where `PICKUPBAR_UITEST_SCREENSHOTS` asks for the PNGs, if anywhere.
    /// `make uitest` sets it to its `UISCREENS` directory.
    static let requestedScreenshotDirectory: URL? =
        ProcessInfo.processInfo.environment["PICKUPBAR_UITEST_SCREENSHOTS"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }

    /// Always writable, because it is inside the runner's sandbox container.
    ///
    /// Xcode builds the UI-test runner with the *app under test's* entitlements,
    /// so for a sandboxed app the runner is sandboxed too and cannot write
    /// outside its container however the requested directory is spelled.
    /// `make uitest` copies this directory's PNGs out to `UISCREENS` after the
    /// run, which is what makes the requested location reliable.
    static let fallbackScreenshotDirectory = URL(fileURLWithPath: NSTemporaryDirectory(),
                                                 isDirectory: true)
        .appendingPathComponent("pickupbar-uiscreens", isDirectory: true)

    /// Every directory a screenshot is written to, best first.
    private lazy var screenshotDirectories: [URL] = {
        var dirs: [URL] = []
        for dir in [Self.requestedScreenshotDirectory, Self.fallbackScreenshotDirectory].compactMap({ $0 }) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if FileManager.default.isWritableFile(atPath: dir.path) { dirs.append(dir) }
        }
        return dirs
    }()

    private var app: XCUIApplication!
    private var mockServer: Process?
    private var port: Int = 0

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false

        XCTAssertFalse(screenshotDirectories.isEmpty,
                       "No writable screenshot directory: tried "
                       + "\(Self.requestedScreenshotDirectory?.path ?? "<none requested>") and "
                       + "\(Self.fallbackScreenshotDirectory.path)")
        print("PickupBarUITests screenshots -> \(screenshotDirectories.map(\.path))")

        (mockServer, port) = try startMockServer()

        app = XCUIApplication()
        app.launchEnvironment = [
            "PICKUPBAR_UITEST": "1",
            "PICKUPBAR_BASE_URL": "http://127.0.0.1:\(port)"
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        // Nil when `make uitest` owns the server's lifetime.
        if let mockServer, mockServer.isRunning {
            mockServer.terminate()
            mockServer.waitUntilExit()
        }
        mockServer = nil
    }

    // MARK: - The walk

    func testHappyPathWalk() throws {
        mark("start")
        openPopover()
        mark("popover open")
        dumpTree("tree-onboarding")

        let key = app.textFields["onboarding.key"]
        require(key, "onboarding")

        screenshot("01-onboarding")
        mark("screenshot 01")

        // 1. Credentials ------------------------------------------------
        type("demo", into: key)
        mark("typed key")
        type("demo", into: app.secureTextFields["onboarding.secret"])
        mark("typed secret")
        app.buttons["onboarding.verify"].click()
        mark("clicked verify")

        // 2. Address ----------------------------------------------------
        let firstName = app.textFields["address.firstName"]
        require(firstName, "address")
        screenshot("02-address")
        mark("screenshot 02")

        type("Todd", into: firstName)
        type("Anglin", into: app.textFields["address.lastName"])
        type("5125551234", into: app.textFields["address.phone"])
        type("1600 Pennsylvania Ave NW", into: app.textFields["address.street"])
        type("Washington", into: app.textFields["address.city"])
        type("DC", into: app.textFields["address.state"])
        type("20500", into: app.textFields["address.zip"])
        app.buttons["address.validate"].click()
        mark("clicked validate")

        // 3. Pickup form ------------------------------------------------
        let schedule = app.buttons["form.schedule"]
        require(schedule, "form")

        mark("form visible")
        dumpTree("tree-form")
        incrementStepper(identifier: "form.stepper.PRIORITY_MAIL", times: 2)
        mark("stepper incremented")

        let weight = app.textFields["form.weight"]
        XCTAssertTrue(weight.exists, "Weight field missing. Tree:\n\(popoverDescription)")
        weight.click()
        weight.typeKey("a", modifierFlags: .command)
        weight.typeText("3\n")

        let hazmat = app.checkBoxes["form.hazmat"]
        XCTAssertTrue(hazmat.exists, "Hazmat checkbox missing. Tree:\n\(popoverDescription)")
        if hazmat.value as? Int != 1 { hazmat.click() }

        mark("form filled")
        screenshot("03-form")

        XCTAssertTrue(schedule.isEnabled, "Schedule button is disabled; the draft is not submittable.")
        schedule.click()

        // The mock sleeps 1.5 s, so the progress screen is up right now.
        mark("clicked schedule")
        screenshot("04-scheduling")

        // 4. Confirmation -----------------------------------------------
        let number = app.staticTexts["confirmation.number"]
        require(number, "confirmation", timeout: 20)
        mark("confirmation visible")
        screenshot("05-confirmation")

        // A SwiftUI `Text` reports its string as the accessibility *value*;
        // `label` is empty.
        let text = (number.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? number.label
        mark("confirmation number = \(text)")
        XCTAssertTrue(text.hasPrefix("WTC"),
                      "Confirmation number \"\(text)\" does not start with WTC.")

        app.buttons["confirmation.another"].click()

        // 5. Back to a fresh form ---------------------------------------
        require(schedule, "form-again")
        mark("form again")
        screenshot("06-form-again")

        // 6. Settings ----------------------------------------------------
        let settingsButton = app.buttons["footer.settings"]
        XCTAssertTrue(settingsButton.exists,
                      "Footer settings button missing. Tree:\n\(popoverDescription)")
        mark("clicking settings")
        settingsButton.click()
        mark("clicked settings")

        let settingsWindow = settingsWindowIfOpened(timeout: 5)
        if let settingsWindow {
            screenshot("07-settings", window: settingsWindow)
        } else {
            screenshot("07-settings-missing")
            XCTFail("""
                PRODUCT BUG: clicking the footer's SettingsLink did not open a Settings \
                window within 5 s. Windows present: \
                \(app.windows.allElementsBoundByIndex.map { "\($0.identifier)/\($0.title)" }).
                Tree:
                \(popoverDescription)
                """)
        }
    }

    // MARK: - Popover

    /// Clicks the app's menu bar status item. `MenuBarExtra` publishes an
    /// `AXMenuBarItem` inside the app's own extra menu bar, which surfaces
    /// differently across macOS versions — try each spelling.
    private func openPopover() {
        let candidates: [XCUIElement] = [
            app.statusItems.firstMatch,
            app.menuBarItems.firstMatch,
            app.menuBars.count > 1
                ? app.menuBars.element(boundBy: 1).children(matching: .menuBarItem).firstMatch
                : app.menuBars.firstMatch.children(matching: .menuBarItem).firstMatch
        ]

        for candidate in candidates where candidate.waitForExistence(timeout: 5) {
            candidate.click()
            if app.textFields["onboarding.key"].waitForExistence(timeout: 5) { return }
            // The click may have toggled the popover shut; try the next spelling.
        }

        XCTFail("""
            Could not open the PickupBar popover: the MenuBarExtra status item was not \
            exposed to the accessibility API. statusItems=\(app.statusItems.count) \
            menuBarItems=\(app.menuBarItems.count) menuBars=\(app.menuBars.count).
            Tree:
            \(popoverDescription)
            """)
    }

    // MARK: - Interaction helpers

    private func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5),
                      "Field \(field.identifier) not found. Tree:\n\(popoverDescription)")
        field.click()
        field.typeText(text)
    }

    /// Clicks a `Stepper`'s increment arrow `times` times.
    ///
    /// `PackageRow` combines its children into one accessibility element, so the
    /// whole row surfaces as a single `Stepper` and `incrementArrows` is empty.
    /// When that happens, click the arrows where they are drawn: at the right
    /// edge of the row, upper arrow in the top half.
    private func incrementStepper(identifier: String, times: Int) {
        let stepper = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        guard require(stepper, "stepper-\(identifier)", timeout: 5) else { return }

        let increment = stepper.incrementArrows.firstMatch
        // Normalized offsets of the up arrow, best guess first.
        let offsets = [CGVector(dx: 0.965, dy: 0.30), CGVector(dx: 0.94, dy: 0.25)]

        for step in 1...times {
            if increment.exists {
                increment.click()
            } else {
                for offset in offsets {
                    stepper.coordinate(withNormalizedOffset: offset).click()
                    if Self.stepperValue(stepper) == step { break }
                }
            }
            mark("stepper \(identifier) = \(Self.stepperValue(stepper).map(String.init) ?? "?")")
        }

        let reached = Self.stepperValue(stepper)
        if reached != times {
            screenshot("99-failure-stepper")
            dumpTree("tree-failure-stepper")
            XCTFail("Stepper \(identifier) is \(reached.map(String.init) ?? "nil") after \(times) "
                    + "increments, expected \(times).")
        }
    }

    /// A combined `Stepper` reports its count through the accessibility value.
    private static func stepperValue(_ stepper: XCUIElement) -> Int? {
        switch stepper.value {
        case let text as String: return Int(text)
        case let number as Int: return number
        default: return nil
        }
    }

    private func settingsWindowIfOpened(timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let named = app.windows["Settings"]
            if named.exists { return named }
            for window in app.windows.allElementsBoundByIndex
            where window.exists && (window.title.contains("Settings")
                                    || window.identifier.contains("Settings")) {
                return window
            }
            _ = XCTWaiter.wait(for: [expectation(description: "poll")], timeout: 0.25)
        }
        return nil
    }

    /// The popover the app puts its UI in. `MenuBarExtra(.window)` publishes it
    /// as an `AXSheet`-style dialog rather than a window, so `app.windows` is
    /// empty and screenshots have to target this instead.
    private var popover: XCUIElement { app.dialogs.firstMatch }

    /// Never use `app.debugDescription` in a failure message: it serializes the
    /// *system* menu bar too, which is enormous and can take minutes.
    private var popoverDescription: String {
        popover.exists ? popover.debugDescription : "<no popover: app.dialogs is empty>"
    }

    /// Waits for `element`, and on timeout leaves a screenshot and the popover's
    /// accessibility tree beside the other screenshots before failing, so a
    /// failing walk is diagnosable from the artifacts alone.
    @discardableResult
    private func require(_ element: XCUIElement,
                         _ what: String,
                         timeout: TimeInterval = 10,
                         file: StaticString = #filePath,
                         line: UInt = #line) -> Bool {
        if element.waitForExistence(timeout: timeout) { return true }
        mark("FAILED waiting for \(what)")
        screenshot("99-failure-\(what)")
        dumpTree("tree-failure-\(what)")
        XCTFail("\(what): \(element) never appeared within \(timeout)s.\n\(popoverDescription)",
                file: file, line: line)
        return false
    }

    // MARK: - Progress markers

    /// Appends a line to `progress.log` in every screenshot directory. A UI
    /// test that wedges inside XCTest's own waiting gives no output at all, so
    /// this file is the only record of how far the walk got.
    private func mark(_ step: String) {
        let line = "\(Date()) \(step)\n"
        for dir in screenshotDirectories {
            let url = dir.appendingPathComponent("progress.log")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Dumps the app's accessibility tree beside the screenshots.
    private func dumpTree(_ name: String) {
        let tree = app.debugDescription
        for dir in screenshotDirectories {
            try? tree.write(to: dir.appendingPathComponent("\(name).txt"),
                            atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Screenshots

    private func screenshot(_ name: String, window: XCUIElement? = nil) {
        XCTContext.runActivity(named: name) { activity in
            let target = window ?? popover
            let shot = target.exists ? target.screenshot() : XCUIScreen.main.screenshot()

            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            activity.add(attachment)

            for dir in screenshotDirectories {
                try? shot.pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
            }
        }
    }

    // MARK: - Mock server

    /// Error type so a broken harness fails the test loudly instead of
    /// quietly skipping it.
    struct HarnessError: Error, CustomStringConvertible {
        let description: String
    }

    /// Brings up the mock USPS server and returns it with its port.
    ///
    /// Normally the test spawns `Scripts/mock-server.py` itself. When the app
    /// under test is sandboxed, though, Xcode signs the UI-test runner with the
    /// app's entitlements, and a sandboxed runner may not listen on a socket --
    /// so `make uitest` starts the server first and passes its port in
    /// `PICKUPBAR_MOCK_PORT`. Either way the server has to answer before the
    /// app launches.
    private func startMockServer() throws -> (Process?, Int) {
        if let raw = ProcessInfo.processInfo.environment["PICKUPBAR_MOCK_PORT"],
           let harnessPort = Int(raw) {
            guard tokenEndpointAnswers(port: harnessPort, timeout: 20) else {
                throw HarnessError(description:
                    "PICKUPBAR_MOCK_PORT=\(harnessPort) was supplied but nothing answered "
                    + "POST /oauth2/v3/token there.")
            }
            return (nil, harnessPort)
        }

        let script = try Self.mockServerURL()
        let python = try Self.pythonURL()
        var lastProblem = "never attempted"

        // The kernel cannot hand out a port and hold it for a child process, so
        // pick an ephemeral port, start the server, and only accept the port
        // once the server actually answers on it.
        for _ in 0..<8 {
            let candidate = Int.random(in: 49_152...65_000)
            let process = Process()
            process.executableURL = python
            process.arguments = [script.path]
            var env = ProcessInfo.processInfo.environment
            env["PORT"] = "\(candidate)"
            env["PYTHONUNBUFFERED"] = "1"
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()

            if tokenEndpointAnswers(port: candidate, timeout: 8) {
                return (process, candidate)
            }

            lastProblem = "port \(candidate) never answered /oauth2/v3/token"
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        throw HarnessError(description: "Could not start \(script.path): \(lastProblem)")
    }

    /// `/usr/bin/python3` is an `xcrun` shim that refuses to run inside a
    /// sandbox, so prefer a real interpreter when one is installed.
    private static func pythonURL() throws -> URL {
        let candidates = [
            "/Library/Developer/CommandLineTools/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw HarnessError(description: "No python3 found in \(candidates)")
    }

    /// Polls `POST /oauth2/v3/token` until it answers or `timeout` elapses.
    private func tokenEndpointAnswers(port: Int, timeout: TimeInterval) -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)/oauth2/v3/token")!
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 2
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(#"{"client_id":"demo","client_secret":"demo"}"#.utf8)

            let semaphore = DispatchSemaphore(value: 0)
            var status: Int?
            URLSession.shared.dataTask(with: request) { _, response, _ in
                status = (response as? HTTPURLResponse)?.statusCode
                semaphore.signal()
            }.resume()
            _ = semaphore.wait(timeout: .now() + 3)

            if status == 200 { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    /// Walks up from this file to the repository root to find the script.
    private static func mockServerURL() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PickupBarUITests
            .deletingLastPathComponent()   // repo root
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Scripts/mock-server.py")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        throw HarnessError(description: "Could not locate Scripts/mock-server.py from \(#filePath)")
    }
}
