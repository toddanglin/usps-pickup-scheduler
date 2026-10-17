import XCTest

/// End-to-end walk of the real Pickup app against `Scripts/mock-server.py`.
///
/// The app is a `MenuBarExtra` (LSUIElement), so there is no ordinary window to
/// drive: the test clicks the status item to open the popover and then walks the
/// whole happy path, screenshotting every screen. Screenshots are attached to
/// the result bundle *and* written to disk (see `screenshotDirectories`) so they
/// can be inspected without opening the .xcresult.
final class PickupUITests: XCTestCase {

    /// Where `PICKUP_UITEST_SCREENSHOTS` asks for the PNGs, if anywhere.
    /// `make uitest` sets it to its `UISCREENS` directory.
    static let requestedScreenshotDirectory: URL? =
        ProcessInfo.processInfo.environment["PICKUP_UITEST_SCREENSHOTS"]
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
        .appendingPathComponent("pickup-uiscreens", isDirectory: true)

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
        print("PickupUITests screenshots -> \(screenshotDirectories.map(\.path))")

        (mockServer, port) = try startMockServer()

        app = XCUIApplication()
        app.launchEnvironment = [
            "PICKUP_UITEST": "1",
            "PICKUP_BASE_URL": "http://127.0.0.1:\(port)"
        ]
        // Tests named "...ConfiguredUser" start with credentials and an address saved.
        if name.contains("ConfiguredUser") {
            app.launchEnvironment["PICKUP_UITEST_SEED"] = "1"
        }
        // `make uitest CLEAN=1`: screenshots without the footer's mock-host label.
        if ProcessInfo.processInfo.environment["PICKUP_UITEST_CLEAN"] == "1" {
            app.launchEnvironment["PICKUP_UITEST_CLEAN"] = "1"
        }
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

    // MARK: - Configured user

    /// A user who already saved credentials and an address sees the pickup form
    /// as the first screen. Regression test: the form's ScrollView once gave the
    /// popover no height, so only the footer was visible.
    func testFormIsFirstScreenForConfiguredUser() throws {
        openPopover()
        let schedule = app.buttons["form.schedule"]
        require(schedule, "form as first screen")
        screenshot("10-form-first-launch")
        XCTAssertTrue(schedule.isHittable, "Schedule Pickup exists but is not on screen")
        XCTAssertGreaterThan(schedule.frame.height, 10)
        assertPopoverFitsForm(schedule)

        // The history is reachable from the footer, and empty for a new user.
        let history = app.buttons["footer.history"]
        require(history, "footer history button")
        history.click()
        require(app.descendants(matching: .any)["history.empty"], "empty history")
        screenshot("11-history-empty")
        let back = app.buttons["history.back"]
        require(back, "history back button")
        back.click()
        require(schedule, "form after history")
    }

    /// The popover is exactly as tall as the form plus the footer: neither
    /// collapsed to the footer, nor stretched to the screen height with empty
    /// space under the form. Regression test for both sizing bugs.
    private func assertPopoverFitsForm(_ schedule: XCUIElement,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let popover = app.dialogs.firstMatch
        let height = popover.frame.height
        mark("popover height \(height); schedule maxY \(schedule.frame.maxY); "
             + "quit minY \(app.buttons["footer.quit"].frame.minY)")
        XCTAssertGreaterThan(height, 400, "The popover collapsed: height \(height)",
                             file: file, line: line)
        XCTAssertLessThan(height, 760, "The popover is taller than the form: height \(height)",
                          file: file, line: line)
        let quit = app.buttons["footer.quit"]
        if quit.exists {
            let gap = quit.frame.minY - schedule.frame.maxY
            XCTAssertLessThan(gap, 60,
                              "Empty space between the form and the footer: \(gap) pt",
                              file: file, line: line)
        } else {
            XCTFail("footer.quit missing", file: file, line: line)
        }
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

        // The verified-address banner stays up until the user continues.
        let continueButton = app.buttons["address.continue"]
        if continueButton.waitForExistence(timeout: 15) {
            screenshot("02b-address-verified")
            continueButton.click()
            mark("clicked continue")
        }

        // 3. Pickup form ------------------------------------------------
        let schedule = app.buttons["form.schedule"]
        require(schedule, "form")

        mark("form visible")
        dumpTree("tree-form")
        incrementStepper(identifier: "form.stepper.PRIORITY_MAIL", times: 2)
        mark("stepper incremented")

        // Counts can also be typed.
        let groundCount = app.textFields["form.count.USPS_GROUND_ADVANTAGE"]
        type("3\n", into: groundCount)
        let total = app.staticTexts["form.total"]
        XCTAssertTrue(total.waitForExistence(timeout: 5), "Total label missing. Tree:\n\(popoverDescription)")
        let totalText = Self.staticText(total)
        mark("total = \(totalText)")
        XCTAssertEqual(totalText, "5 total", "Typing 3 Ground Advantage next to 2 Priority Mail")

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

        XCTAssertTrue(app.buttons["confirmation.another"].exists,
                      "Schedule another pickup button missing")

        // 5. History, after a change made on usps.com --------------------
        // The mock moves the pickup a day later, as if changed on usps.com;
        // opening the history checks with USPS and marks the row.
        let changedDate = mockChangeOnUSPS(text)
        mark("changed \(text) on the mock to \(changedDate ?? "?")")
        XCTAssertNotNil(changedDate, "POST /__mock/pickups/\(text)/modify failed")

        let historyLink = app.buttons["confirmation.history"]
        require(historyLink, "confirmation history link")
        historyLink.click()
        let row = app.staticTexts["history.number.\(text)"]
        require(row, "history row \(text)")
        XCTAssertTrue(app.buttons["history.copy.\(text)"].exists, "History copy button missing")
        let dot = app.descendants(matching: .any)["history.changed.\(text)"]
        require(dot, "changed-on-usps.com dot", timeout: 15)
        if let changedDate {
            XCTAssertEqual(Self.staticText(app.staticTexts["history.date.\(text)"]),
                           Self.shortDisplayDate(changedDate),
                           "The row should show the date USPS now has")
        }
        XCTAssertFalse(app.descendants(matching: .any)["history.checking"].exists,
                       "The checking indicator should be gone once the check finished")
        mark("history shows the change")
        screenshot("08b-history-changed")

        // Shown again, the dot is gone (and the check is throttled).
        app.buttons["history.back"].click()
        require(schedule, "form after the changed history")
        let footerHistory = app.buttons["footer.history"]
        require(footerHistory, "footer history button")
        footerHistory.click()
        require(row, "history row \(text) again")
        XCTAssertFalse(dot.exists, "The dot should clear the next time the list is shown")
        mark("history visible")
        screenshot("08-history")
        XCTAssertLessThan(popover.frame.height, 760,
                          "The history is taller than it should be: height \(popover.frame.height)")

        // 5b. Modify, then cancel, the pickup --------------------------
        modifyThenCancelFirstPickup()
        app.buttons["history.back"].click()

        // 6. Back to a fresh form ---------------------------------------
        // Leaving the history after a confirmation is the same as "Schedule
        // another pickup": a fresh form.
        require(schedule, "form-again")
        mark("form again")
        screenshot("06-form-again")
        XCTAssertEqual(Self.staticText(app.staticTexts["form.total"]), "0 total",
                       "The form after a confirmation should start fresh")
        XCTAssertLessThan(popover.frame.height, 760,
                          "The popover is taller than the form: height \(popover.frame.height)")

        // 6. Settings ----------------------------------------------------
        let settingsButton = app.buttons["footer.settings"]
        XCTAssertTrue(settingsButton.exists,
                      "Footer settings button missing. Tree:\n\(popoverDescription)")
        mark("clicking settings")
        settingsButton.click()
        mark("clicked settings")

        let settingsWindow = settingsWindowIfOpened(timeout: 5)
        if let settingsWindow {
            // The Settings window reopens on whichever tab was last chosen,
            // even across runs, so pick Account explicitly.
            if let accountTab = settingsTab("Account", in: settingsWindow) {
                accountTab.click()
            }
            screenshot("07-settings", window: settingsWindow)

            // Settings › Defaults: the "Estimated weight" row must be one line
            // (it once wrapped to "Weig/ht" beside the field).
            if let defaultsTab = settingsTab("Defaults", in: settingsWindow) {
                mark("clicking defaults tab")
                defaultsTab.click()
                let weight = settingsWindow.textFields["defaults.weight"]
                require(weight, "defaults weight field", timeout: 5)
                screenshot("07b-settings-defaults", window: settingsWindow)
                XCTAssertLessThan(weight.frame.height, 30,
                                  "The default weight field is taller than one line: \(weight.frame)")
            }

            // Settings › General shows MARKETING_VERSION.
            if let generalTab = settingsTab("General", in: settingsWindow) {
                generalTab.click()
                screenshot("07c-settings-general", window: settingsWindow)
            }
            // Leave Account selected for the next run and for real use.
            settingsTab("Account", in: settingsWindow)?.click()
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

    // MARK: - Modify / cancel

    /// From the history: Modify… the first pickup (3 Ground Advantage → weight
    /// 4), save, come back, then Cancel pickup… it.
    private func modifyThenCancelFirstPickup() {
        let numberPrefix = "history.number."
        let firstNumber = app.staticTexts
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", numberPrefix)).firstMatch
        guard require(firstNumber, "a history row") else { return }
        let conf = String(firstNumber.identifier.dropFirst(numberPrefix.count))
        mark("modifying \(conf)")

        guard chooseRowAction(conf: conf, identifier: "history.modify.\(conf)", title: "Modify…") else { return }

        let save = app.buttons["form.save"]
        guard require(save, "modify form", timeout: 15) else { return }
        XCTAssertEqual(Self.staticText(app.staticTexts["form.title"]), "Modify pickup")
        let ground = app.textFields["form.count.USPS_GROUND_ADVANTAGE"]
        XCTAssertEqual(ground.value as? String, "3", "The form should show the pickup's 3 Ground Advantage")
        XCTAssertLessThan(popover.frame.height, 760,
                          "The modify form is taller than it should be: height \(popover.frame.height)")
        XCTAssertTrue(app.buttons["form.discard"].exists, "Discard button missing")
        XCTAssertFalse(app.buttons["form.lastPickup"].exists, "The last-pickup caption shows while modifying")

        let weight = app.textFields["form.weight"]
        weight.click()
        weight.typeKey("a", modifierFlags: .command)
        weight.typeText("4\n")
        let hazmat = app.checkBoxes["form.hazmat"]
        if hazmat.value as? Int != 1 { hazmat.click() }
        mark("modify form filled")
        screenshot("09a-modify-form")

        XCTAssertTrue(save.isEnabled, "Save Changes is disabled")
        save.click()
        mark("clicked save")

        let title = app.staticTexts["confirmation.title"]
        guard require(title, "updated confirmation", timeout: 20) else { return }
        XCTAssertEqual(Self.staticText(title), "Pickup updated")
        screenshot("09-updated")

        let done = app.buttons["confirmation.done"]
        guard require(done, "Done button") else { return }
        done.click()
        guard require(app.descendants(matching: .any)["history.updated.\(conf)"], "Updated caption") else { return }
        mark("history shows Updated")

        // Cancel it --------------------------------------------------
        guard chooseRowAction(conf: conf, identifier: "history.cancel.\(conf)",
                              title: "Cancel pickup…") else { return }
        let confirm = app.descendants(matching: .any)["history.cancelConfirm"]
        let confirmByTitle = app.buttons["Cancel pickup"]
        if !confirm.waitForExistence(timeout: 5) && !confirmByTitle.exists {
            require(confirm, "cancel confirmation dialog")
            return
        }
        screenshot("09b0-cancel-confirm")
        (confirm.exists ? confirm : confirmByTitle).click()
        mark("confirmed cancel")

        let badge = app.descendants(matching: .any)["history.status.\(conf)"]
        guard require(badge, "Cancelled badge", timeout: 15) else { return }
        XCTAssertEqual(badge.label, "Cancelled")
        XCTAssertFalse(app.descendants(matching: .any)["history.updated.\(conf)"].exists,
                       "A cancelled row should not also say Updated")
        XCTAssertLessThan(popover.frame.height, 760,
                          "The history is taller than it should be: height \(popover.frame.height)")
        screenshot("09b-cancelled")
        mark("cancelled \(conf)")
    }

    /// Opens a history row's "More" menu and picks an item, by identifier
    /// when SwiftUI passed it to the menu item, else by title.
    @discardableResult
    private func chooseRowAction(conf: String, identifier: String, title: String) -> Bool {
        let more = app.descendants(matching: .any)["history.more.\(conf)"]
        guard require(more, "More menu of \(conf)") else { return false }
        more.click()
        let byID = app.menuItems[identifier]
        let byTitle = app.menuItems[title]
        if byID.waitForExistence(timeout: 3) {
            byID.click()
            return true
        }
        if byTitle.waitForExistence(timeout: 2) {
            mark("menu item \(identifier) found by title only")
            byTitle.click()
            return true
        }
        return require(byID, "menu item \(identifier)")
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
            // Any popover counts: a configured user lands on the form, not onboarding.
            if app.dialogs.firstMatch.waitForExistence(timeout: 5) { return }
            // The click may have toggled the popover shut; try the next spelling.
        }

        XCTFail("""
            Could not open the Pickup popover: the MenuBarExtra status item was not \
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

    /// Clicks a `Stepper`'s increment arrow `times` times. `PackageRow` keeps
    /// the stepper its own accessibility element, so its arrows are reachable.
    private func incrementStepper(identifier: String, times: Int) {
        let stepper = app.steppers[identifier]
        guard require(stepper, "stepper-\(identifier)", timeout: 5) else { return }
        let increment = stepper.incrementArrows.firstMatch
        guard require(increment, "increment arrow of \(identifier)", timeout: 5) else { return }

        for _ in 1...times {
            increment.click()
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

    /// A SwiftUI `Text` reports its string as the accessibility *value*;
    /// `label` is usually empty.
    private static func staticText(_ element: XCUIElement) -> String {
        (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
    }

    /// A `Stepper` reports its count through the accessibility value.
    private static func stepperValue(_ stepper: XCUIElement) -> Int? {
        switch stepper.value {
        case let text as String: return Int(text)
        case let number as Int: return number
        default: return nil
        }
    }

    /// A Settings tab's toolbar button, or nil (and a failure) if it is missing.
    private func settingsTab(_ title: String, in window: XCUIElement) -> XCUIElement? {
        let inToolbar = window.toolbars.buttons[title]
        let tab = inToolbar.waitForExistence(timeout: 5) ? inToolbar : window.buttons[title]
        return require(tab, "settings \(title) tab", timeout: 5) ? tab : nil
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

    /// `POST /__mock/pickups/{number}/modify`: the mock moves the pickup a day
    /// later and changes its weight, as a change on usps.com would. Returns the
    /// new "yyyy-MM-dd" date, or nil. An outbound request works from the
    /// sandboxed runner (only listening does not).
    private func mockChangeOnUSPS(_ number: String) -> String? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/__mock/pickups/\(number)/modify")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        let semaphore = DispatchSemaphore(value: 0)
        var date: String?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200,
               let data,
               let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                date = body["pickupDate"] as? String
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 6)
        return date
    }

    /// "yyyy-MM-dd" as the history row shows it, e.g. "Tue, Oct 20".
    private static func shortDisplayDate(_ apiDate: String) -> String {
        let timeZone = TimeZone(identifier: "America/Chicago")!
        let parser = DateFormatter()
        parser.timeZone = timeZone
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let day = parser.date(from: apiDate) else { return apiDate }
        let display = DateFormatter()
        display.timeZone = timeZone
        display.locale = Locale(identifier: "en_US_POSIX")
        display.dateFormat = "EEE, MMM d"
        return display.string(from: day)
    }

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
    /// `PICKUP_MOCK_PORT`. Either way the server has to answer before the
    /// app launches.
    private func startMockServer() throws -> (Process?, Int) {
        if let raw = ProcessInfo.processInfo.environment["PICKUP_MOCK_PORT"],
           let harnessPort = Int(raw) {
            guard tokenEndpointAnswers(port: harnessPort, timeout: 20) else {
                throw HarnessError(description:
                    "PICKUP_MOCK_PORT=\(harnessPort) was supplied but nothing answered "
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
            .deletingLastPathComponent()   // PickupUITests
            .deletingLastPathComponent()   // repo root
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Scripts/mock-server.py")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        throw HarnessError(description: "Could not locate Scripts/mock-server.py from \(#filePath)")
    }
}
