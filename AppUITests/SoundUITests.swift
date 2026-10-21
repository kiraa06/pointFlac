import XCTest

/// Plan 4's Sound tab: Pure is the master switch, a block turns processing on, and the strip says so; Pure turns it
/// off again. Every launch is muted (ruling R22) and starts from Pure defaults (`-PFResetSound`), so no earlier run's
/// settings leak in.
///
/// The simulator's route is the built-in speaker, where the SIGNAL cell shows the delivered resolution ("Pure · iOS
/// speaker tuning") and the altered states sit in the note beside the title (`titleNote`). So "Processing" is looked
/// for in both places: the note on the speaker, the cell's words on any other route.
final class SoundUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testEQTurnsProcessingOnAndPureTurnsItOff() {
        let app = launch()
        // A failed run would leave Pure off for the next test's launch: put the defaults back.
        addTeardownBlock { @MainActor [weak self] in
            if self?.testRun?.hasSucceeded == false { Self.resetSound() }
        }
        let strip = app.descendants(matching: .any)["signalStrip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 8))
        expectation(for: NSPredicate(format: "label == 'Pause'"), evaluatedWith: app.buttons["playButton"])
        waitForExpectations(timeout: 8)
        // The plan has arrived once the strip shows the DAC cell's rate.
        expectation(for: NSPredicate(format: "label CONTAINS 'kHz'"), evaluatedWith: strip)
        waitForExpectations(timeout: 8)
        XCTAssertFalse(Self.saysProcessing(app), "Pure by default, the strip reads \"\(strip.label)\"")

        app.tabBars.buttons["Sound"].tap()
        let pure = app.descendants(matching: .any)["pureSwitch"]
        XCTAssertTrue(pure.waitForExistence(timeout: 3))
        XCTAssertEqual(pure.value as? String, "1")
        pure.tap()
        expectation(for: NSPredicate(format: "value == '0'"), evaluatedWith: pure)
        waitForExpectations(timeout: 2)

        // The EQ comes after ReplayGain, the preamp and headphone correction, in chain order.
        let eq = app.descendants(matching: .any)["eqToggle"]
        Self.reveal(eq, in: app)
        XCTAssertTrue(eq.exists)
        Self.flip(eq)
        expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: eq)
        waitForExpectations(timeout: 2)

        let presets = app.buttons["eqPresetMenu"]
        Self.reveal(presets, in: app)
        XCTAssertTrue(presets.exists)
        presets.tap()
        let bassBoost = app.buttons["Bass Boost"]
        XCTAssertTrue(bassBoost.waitForExistence(timeout: 2))
        bassBoost.tap()
        expectation(for: NSPredicate(format: "label CONTAINS 'Bass Boost'"), evaluatedWith: presets)
        waitForExpectations(timeout: 2)

        app.tabBars.buttons["Player"].tap()
        expectation(for: NSPredicate { _, _ in Self.saysProcessing(app) }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)

        // Spec §5.7: tapping Processing opens the chain. The details sheet's Open Sound goes back to the Sound tab.
        strip.tap()
        let open = app.buttons["openSoundButton"]
        XCTAssertTrue(open.waitForExistence(timeout: 3))
        open.tap()
        // The tab keeps its place, down at the EQ: back up to Pure.
        XCTAssertTrue(app.navigationBars["Sound"].waitForExistence(timeout: 3))
        Self.reveal(pure, in: app, up: true)
        XCTAssertTrue(pure.exists)
        XCTAssertEqual(pure.value as? String, "0")
        pure.tap()
        expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: pure)
        waitForExpectations(timeout: 2)
        // Pure bypasses the EQ without switching it off, so turning Pure off again brings it back.
        Self.reveal(eq, in: app)
        XCTAssertEqual(eq.value as? String, "1")

        app.tabBars.buttons["Player"].tap()
        expectation(for: NSPredicate { _, _ in !Self.saysProcessing(app) }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        // "Pure" needs the hardware at the file's rate. The demo album is 48 kHz; a Mac whose output runs at another
        // rate resamples it, and then the strip rightly claims nothing.
        let label = strip.label
        if label.contains("48 kHz") {
            XCTAssertTrue(label.contains("Pure"), "the signal strip reads \"\(label)\"")
        } else {
            // Not a failure, but never a silent one: the report shows the check was skipped, and why.
            XCTContext.runActivity(named: "Pure check skipped: this Mac's output resamples. Strip: \(label)") { _ in }
        }
        XCTAssertFalse(label.contains("Processing"), "the signal strip reads \"\(label)\"")
    }

    /// The faders and handles take a drag inside the scrolling list, a scroll that starts on the fader bank scrolls
    /// rather than moving a fader, a handle follows the finger, a pinch over a handle sets its Q without moving it, and
    /// the edits are saved both ways: after the half-second debounce, and at once when the app leaves the foreground.
    @MainActor
    func testEQDragsMoveTheControlsAndSurviveARelaunch() {
        let app = launch()
        addTeardownBlock { @MainActor in Self.resetSound() }
        app.tabBars.buttons["Sound"].tap()
        let pure = app.descendants(matching: .any)["pureSwitch"]
        XCTAssertTrue(pure.waitForExistence(timeout: 5))
        pure.tap()
        let eq = app.descendants(matching: .any)["eqToggle"]
        Self.reveal(eq, in: app)
        XCTAssertTrue(eq.exists)
        Self.flip(eq)
        expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: eq)
        waitForExpectations(timeout: 2)

        // Graphic: a scroll that starts on the bank, below the caps, scrolls the list and moves no fader.
        let fader = app.descendants(matching: .any)["graphicBand-0"]
        Self.reveal(fader, in: app)
        XCTAssertTrue(fader.waitForExistence(timeout: 2))
        Self.scrollClear(fader, in: app)
        XCTAssertEqual(fader.value as? String, "0 decibels")
        let top = fader.frame.minY
        let low = fader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.86))
        low.press(forDuration: 0.05, thenDragTo: low.withOffset(CGVector(dx: 0, dy: -90)))
        XCTAssertEqual(fader.value as? String, "0 decibels", "a scroll on the bank moved the fader")
        XCTAssertLessThan(fader.frame.minY, top - 40, "a scroll on the bank did not scroll the list")
        Self.scroll(app, by: 90)
        Self.scrollClear(fader, in: app)

        // The cap itself (at 0 dB, the middle of the strip) takes the drag.
        let from = fader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = fader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        from.press(forDuration: 0.1, thenDragTo: to)
        expectation(for: NSPredicate(format: "value BEGINSWITH 'plus'"), evaluatedWith: fader)
        waitForExpectations(timeout: 2)
        XCTAssertTrue(app.buttons["eqPresetMenu"].label.contains("Custom"))

        // Parametric: add a band, then drag its handle up and to the right.
        let parametric = app.descendants(matching: .any)["eqModePicker"].buttons["Parametric"]
        XCTAssertTrue(parametric.waitForExistence(timeout: 2))
        parametric.tap()
        let add = app.buttons["addBandButton"]
        if !add.waitForExistence(timeout: 2) { Self.scroll(app) }
        XCTAssertTrue(add.waitForExistence(timeout: 2))
        Self.scrollClear(add, in: app)
        add.tap()
        // The graph sits above the band list: scroll back to it if the list has moved it off screen.
        let handle = app.descendants(matching: .any)["eqHandle-0"]
        for _ in 0..<4 where !handle.waitForExistence(timeout: 1) { Self.scroll(app, by: 180) }
        XCTAssertTrue(handle.exists)
        // Clear of the floating tab bar, which would take the press.
        Self.scrollClear(handle, in: app)
        XCTAssertEqual(handle.value as? String, "1 kilohertz, 0 decibels, Q 1.00")

        // The handle lands where the finger does: 110 pt right and 40 pt up on the log axis and ±24 dB scale.
        let graph = app.descendants(matching: .any)["eqGraph"].frame
        let (dx, dy) = (110.0, -40.0)
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: dx, dy: dy)))
        let startX = graph.width * log10(1000 / 20.0) / 3
        let expectedHz = 20 * pow(1000, (startX + dx) / graph.width)
        let expectedDb = -dy / graph.height * 48
        expectation(for: NSPredicate(format: "NOT (value BEGINSWITH '1 kilohertz')"), evaluatedWith: handle)
        waitForExpectations(timeout: 2)
        let dragged = Self.band(handle.value as? String)
        XCTAssertNotNil(dragged, "handle reads \(String(describing: handle.value))")
        if let dragged {
            XCTAssertLessThan(
                abs(log2(dragged.hz / expectedHz)), 0.25,
                "the handle is at \(dragged.hz) Hz, the finger at \(expectedHz) Hz")
            XCTAssertLessThan(
                abs((dragged.db ?? 0) - expectedDb), 1.2,
                "the handle is at \(dragged.db ?? 0) dB, the finger at \(expectedDb) dB")
        }

        // A pinch over the handle itself sets its Q, spread to widen it, and leaves its frequency and gain alone.
        let beforePinch = handle.value as? String
        handle.pinch(withScale: 2.5, velocity: 2)
        expectation(for: NSPredicate(format: "value CONTAINS 'Q 0.'"), evaluatedWith: handle)
        waitForExpectations(timeout: 3)
        let moved = handle.value as? String
        XCTAssertEqual(
            moved?.components(separatedBy: ", ").prefix(2), beforePinch?.components(separatedBy: ", ").prefix(2),
            "the pinch moved the band")

        // The save follows half a second after the last change; a relaunch loads it.
        Thread.sleep(forTimeInterval: 1.2)
        app.terminate()
        // This launch's debounce is 30 s, so within the test only the flush on leaving the foreground can save.
        let again = relaunch(["-PFSoundSaveDelay", "30"])
        let pureAgain = again.descendants(matching: .any)["pureSwitch"]
        XCTAssertTrue(pureAgain.waitForExistence(timeout: 5))
        XCTAssertEqual(pureAgain.value as? String, "0")
        let handleAgain = again.descendants(matching: .any)["eqHandle-0"]
        Self.reveal(handleAgain, in: again)
        XCTAssertTrue(handleAgain.waitForExistence(timeout: 2))
        XCTAssertEqual(handleAgain.value as? String, moved)

        // Swiping the band's row deletes it, handle and all.
        let row = again.descendants(matching: .any)["bandRow-0"]
        Self.reveal(row, in: again)
        XCTAssertTrue(row.waitForExistence(timeout: 2))
        Self.scrollClear(row, in: again)
        let middle = row.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        middle.press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)))
        let delete = again.buttons["Delete"]
        if delete.waitForExistence(timeout: 2) { delete.tap() }
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: handleAgain)
        waitForExpectations(timeout: 3)

        // Home straight after the edit, long before the 30 s debounce: leaving the foreground must write it at once.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 0.5)
        again.terminate()
        let third = relaunch()
        XCTAssertTrue(third.descendants(matching: .any)["pureSwitch"].waitForExistence(timeout: 5))
        let empty = third.buttons["copyGraphicButton"]
        Self.reveal(empty, in: third)
        XCTAssertTrue(empty.exists, "the deleted band came back: the flush on leaving the foreground was lost")
    }

    /// A corrupt `sound.json` (here, Pure off and the EQ on under an unknown EQ mode) loads as Pure, with every block
    /// off: `SoundSettings.decode` falls back to the defaults rather than half-reading it.
    @MainActor
    func testCorruptSoundFileLoadsAsPure() {
        let app = XCUIApplication()
        app.launchArguments = ["-PFPreloadFixtures", "-PFMuteOutput", "-PFCorruptSound", "-PFStage", "deck"]
        app.launch()
        addTeardownBlock { @MainActor in Self.resetSound() }
        app.tabBars.buttons["Sound"].tap()
        let pure = app.descendants(matching: .any)["pureSwitch"]
        XCTAssertTrue(pure.waitForExistence(timeout: 5))
        XCTAssertEqual(pure.value as? String, "1")
        let eq = app.descendants(matching: .any)["eqToggle"]
        Self.reveal(eq, in: app)
        XCTAssertTrue(eq.exists)
        XCTAssertEqual(eq.value as? String, "0")
    }

    // MARK: Helpers

    /// Scrolls the list by `distance` points (negative moves the content up), dragging in the margin beside the
    /// cards so no control is touched.
    @MainActor
    private static func scroll(_ app: XCUIApplication, by distance: CGFloat = -180) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: distance < 0 ? 0.7 : 0.3))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: distance)))
    }

    /// Scrolls the list down (`up`: up) until `element` is on screen, then clear of the floating tab bar. The list is
    /// lazy, so a row far away does not exist until it is near.
    @MainActor
    private static func reveal(_ element: XCUIElement, in app: XCUIApplication, up: Bool = false) {
        for _ in 0..<14 {
            if element.exists, element.isHittable { break }
            scroll(app, by: up ? 220 : -220)
        }
        scrollClear(element, in: app)
    }

    /// Scrolls until `element` sits above the floating tab bar.
    @MainActor
    private static func scrollClear(_ element: XCUIElement, in app: XCUIApplication) {
        let bar = app.tabBars.firstMatch
        for _ in 0..<6 {
            let limit = (bar.exists ? bar.frame.minY : app.frame.maxY) - 16
            guard element.exists, element.frame.maxY > limit else { return }
            scroll(app)
        }
    }

    /// The app again, keeping the saved Sound settings, on the Sound tab.
    @MainActor
    private func relaunch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-PFPreloadFixtures", "-PFMuteOutput", "-PFStage", "deck"] + extra
        app.launch()
        app.tabBars.buttons["Sound"].tap()
        return app
    }

    /// A handle's spoken value, "8.77 kilohertz, plus 9.6 decibels, Q 1.00", as numbers. No gain for the types that
    /// ignore it.
    private static func band(_ value: String?) -> (hz: Double, db: Double?, q: Double)? {
        guard let parts = value?.components(separatedBy: ", "), parts.count >= 2 else { return nil }
        let f = parts[0].split(separator: " ")
        guard f.count == 2, let n = Double(f[0]) else { return nil }
        let hz = f[1] == "kilohertz" ? n * 1000 : n
        var db: Double?
        if parts.count == 3 {
            let g = parts[1].split(separator: " ")
            if g.count == 3, let v = Double(g[1]) {
                db = g[0] == "minus" ? -v : v
            } else if g.count == 2, let v = Double(g[0]) {
                db = v
            }
        }
        guard let last = parts.last?.split(separator: " ").last, let q = Double(last) else { return nil }
        return (hz, db, q)
    }

    /// Puts the Pure defaults back for the tests that follow.
    @MainActor
    private static func resetSound() {
        let reset = XCUIApplication()
        reset.launchArguments = ["-PFResetSound", "-PFMuteOutput"]
        reset.launch()
        reset.terminate()
    }

    /// "Processing" in the SIGNAL cell (a route without a resolution claim) or in the note beside the title.
    @MainActor
    private static func saysProcessing(_ app: XCUIApplication) -> Bool {
        let strip = app.descendants(matching: .any)["signalStrip"]
        let note = app.descendants(matching: .any)["titleNote"]
        return strip.label.contains("Processing") || (note.exists && note.label.contains("Processing"))
    }

    /// A switch row's control is its right-hand end; a tap in the middle can land on the label.
    @MainActor
    private static func flip(_ toggle: XCUIElement) {
        let control = toggle.switches.firstMatch
        if control.exists {
            control.tap()
        } else {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
    }

    /// Plays Copper Garden, the 48 kHz demo album, so a 48 kHz Mac output can show Pure.
    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-PFPreloadFixtures", "-PFMuteOutput", "-PFDemoPlay", "-PFDemoAlbum", "Copper Garden", "-PFResetSound",
            "-PFStage", "deck",
        ]
        app.launch()
        return app
    }
}
