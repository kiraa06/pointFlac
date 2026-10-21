import XCTest

/// Plan 3's app: the tabs, the Shelf's search, the Deck/Cover switch, the tonearm, Get Music's suggestions and the
/// Downloads list. Every launch is muted (ruling R22). The demo albums ship in Debug builds with the fixtures, so the
/// shelf has records to find and the deck has sides to seek across.
final class PlayerUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTabsNavigate() {
        let app = launch()
        XCTAssertTrue(app.buttons["shelfButton"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Get Music"].tap()
        XCTAssertTrue(app.navigationBars["Get Music"].waitForExistence(timeout: 3))
        app.tabBars.buttons["Downloads"].tap()
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 3))
        app.tabBars.buttons["Settings"].tap()
        // Diagnostics sits below Privacy and Soulseek, so it may be off screen.
        if !app.buttons["diagnosticsLink"].waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(app.buttons["diagnosticsLink"].waitForExistence(timeout: 3))
        app.tabBars.buttons["Player"].tap()
        XCTAssertTrue(app.buttons["shelfButton"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testShelfSearchShowsResultsAsYouType() {
        let app = launch()
        openShelf(app)
        let field = app.textFields["shelfSearch"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("neon")
        XCTAssertTrue(app.buttons["result-track-Neon Mile"].waitForExistence(timeout: 2))
        // One-letter typo tolerance: "lumin" still finds Lumen Arcade's album.
        field.typeText(XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue)
        field.typeText(XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue)
        field.typeText("lumin")
        XCTAssertTrue(app.buttons["result-album-Night Drive"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["searchTiming"].exists)
    }

    /// Spec §4.6: online results stream in under the local ones, labelled by source. Search starts them at once.
    @MainActor
    func testShelfStreamsOnlineResultsUnderLocalOnes() {
        let app = launch()
        openShelf(app)
        let field = app.textFields["shelfSearch"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("verdigris\n")
        XCTAssertTrue(app.buttons["result-track-Verdigris"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["shelfDownload-ia-Verdigris-1"].waitForExistence(timeout: 4))
    }

    @MainActor
    func testFilterChipsNarrowTheShelf() {
        let app = launch()
        openShelf(app)
        let field = app.textFields["shelfSearch"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        // Shelf search matches word starts: "t" finds Hydrophone (by The Tidelines, the only 32-bit album) and Night
        // Drive's "Tail Lights" (24/96).
        field.typeText("t")
        XCTAssertTrue(app.buttons["result-album-Hydrophone"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["result-track-Tail Lights"].exists)
        app.buttons["chip-32bit"].tap()
        XCTAssertTrue(app.buttons["result-album-Hydrophone"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["result-track-Tail Lights"].exists)
    }

    @MainActor
    func testSleeveTapRunsTheHandoffAndPlays() {
        let app = launch()
        openShelf(app)
        let sleeve = app.descendants(matching: .any)["sleeve-0"]
        XCTAssertTrue(sleeve.waitForExistence(timeout: 3))
        sleeve.tap()
        // Mid-flight frames, kept in the result bundle for review: the record leaving the sleeve, then on the platter.
        for (delay, name) in [(1.6, "handoff-1.6s"), (1.4, "handoff-3.0s"), (1.0, "handoff-4.0s")] {
            Thread.sleep(forTimeInterval: delay)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
        }
        // The hand-off takes about 4.7 s at Kiran's slow-mo pace; then the needle drops and the title shows.
        let title = app.staticTexts["nowPlayingTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        let playing = NSPredicate(format: "label == 'Pause'")
        expectation(for: playing, evaluatedWith: app.buttons["playButton"])
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testDeckCoverSwitch() {
        let app = launch(demoPlay: true)
        XCTAssertTrue(app.descendants(matching: .any)["deckRecord"].waitForExistence(timeout: 8))
        tapUntil(app.buttons["stageCover"], shows: app.descendants(matching: .any)["coverArt"])
        XCTAssertFalse(app.descendants(matching: .any)["tonearmHandle"].exists)
        tapUntil(app.buttons["stageDeck"], shows: app.descendants(matching: .any)["tonearmHandle"])
    }

    @MainActor
    func testTonearmDragSeeksAcrossTheSide() {
        let app = launch(demoPlay: true)
        let title = app.staticTexts["nowPlayingTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        XCTAssertEqual(title.label, "Ignition")
        let handle = app.descendants(matching: .any)["tonearmHandle"]
        let record = app.descendants(matching: .any)["deckRecord"]
        XCTAssertTrue(handle.waitForExistence(timeout: 3) && record.exists)
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = record.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.62))
        start.press(forDuration: 0.3, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        // The needle went down well inside side A (Ignition, Neon Mile, Overpass): another track, or far into this one.
        let moved = NSPredicate { _, _ in
            title.label != "Ignition" || Self.seconds(app.staticTexts["elapsedTime"].label) >= 20
        }
        expectation(for: moved, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
    }

    /// Spec §4.3 and §6.4: turning the record scrubs (the music follows the hand), and letting go spins it back up and
    /// plays on, with the strip back from "Scrubbing".
    @MainActor
    func testPlatterScrubPlaysOnAfterLettingGo() {
        let app = launch(demoPlay: true)
        let record = app.descendants(matching: .any)["deckRecord"]
        XCTAssertTrue(record.waitForExistence(timeout: 8))
        let playing = NSPredicate(format: "label == 'Pause'")
        expectation(for: playing, evaluatedWith: app.buttons["playButton"])
        waitForExpectations(timeout: 5)
        let from = record.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        let to = record.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        from.press(forDuration: 0.4, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.4)
        let settled = NSPredicate { _, _ in
            app.buttons["playButton"].label == "Pause" && !app.buttons["signalStrip"].label.contains("Scrubbing")
        }
        expectation(for: settled, evaluatedWith: nil)
        waitForExpectations(timeout: 6)
    }

    @MainActor
    func testGetMusicSuggestionsAppearAsYouType() {
        let app = launch()
        app.tabBars.buttons["Get Music"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("lumen")
        // The library's hit at once, then the registry's.
        XCTAssertTrue(app.buttons["suggestion-0"].waitForExistence(timeout: 2))
        let library = app.buttons.matching(NSPredicate(format: "label CONTAINS 'In your library'")).firstMatch
        XCTAssertTrue(library.exists)
        let registry = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Demo registry'")).firstMatch
        XCTAssertTrue(registry.waitForExistence(timeout: 3))
        app.buttons["suggestion-0"].tap()
        let download = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'download-'")).firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 4))
    }

    @MainActor
    func testDownloadShowsProgressInDownloads() {
        let app = launch()
        app.tabBars.buttons["Get Music"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("test\n")
        let download = app.buttons["download-ia-Test-1"]
        XCTAssertTrue(download.waitForExistence(timeout: 4))
        // Internet Archive rows show their licence.
        XCTAssertTrue(app.descendants(matching: .any)["licence-ia-Test-1"].exists)
        download.tap()
        app.tabBars.buttons["Downloads"].tap()
        let row = app.descendants(matching: .any)["downloadRow-ia-Test-1"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        expectation(for: NSPredicate(format: "label CONTAINS 'Downloading'"), evaluatedWith: row)
        waitForExpectations(timeout: 4)
        expectation(for: NSPredicate(format: "label CONTAINS 'Done'"), evaluatedWith: row)
        waitForExpectations(timeout: 10)
    }

    /// The crate's flick, measured: UIKit's scroll-deceleration hitch ratio while the coverflow decelerates. No
    /// baseline is set; the numbers land in the log. The simulator's figures only hint at the device's (spec §8
    /// wants < 1 ms/s at 120 Hz on the iPhone itself).
    @MainActor
    func testCrateFlickHitchRatio() {
        let app = launch()
        openShelf(app)
        let front = app.descendants(matching: .any)["sleeve-0"]
        XCTAssertTrue(front.waitForExistence(timeout: 3))
        let y = front.frame.midY / app.frame.height
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: y))
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: y))
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric], options: options) {
            right.press(forDuration: 0.01, thenDragTo: left, withVelocity: .fast, thenHoldForDuration: 0)
            left.press(forDuration: 0.01, thenDragTo: right, withVelocity: .fast, thenHoldForDuration: 0)
        }
    }

    @MainActor
    func testMonochromeToggle() {
        let app = launch(demoPlay: true)
        XCTAssertTrue(app.buttons["shelfButton"].waitForExistence(timeout: 5))
        let toggle = openMonochromeToggle(app)
        // Start from a known state: the setting survives launches, so an earlier run may have left it on.
        if toggle.value as? String == "1" { flip(toggle) }
        XCTAssertEqual(toggle.value as? String, "0")
        flip(toggle)
        XCTAssertEqual(toggle.value as? String, "1")
        app.tabBars.buttons["Player"].tap()
        XCTAssertTrue(app.buttons["shelfButton"].waitForExistence(timeout: 3))
        app.terminate()

        let relaunched = launch()
        XCTAssertTrue(relaunched.buttons["shelfButton"].waitForExistence(timeout: 5))
        let persisted = openMonochromeToggle(relaunched)
        XCTAssertEqual(persisted.value as? String, "1")
        // Leave the app as found.
        flip(persisted)
        XCTAssertEqual(persisted.value as? String, "0")
    }

    // MARK: Helpers

    /// A Form row's switch is the right-hand end of the row; a tap in the middle only hits the label.
    @MainActor
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    @MainActor
    private func openMonochromeToggle(_ app: XCUIApplication) -> XCUIElement {
        app.tabBars.buttons["Settings"].tap()
        let toggle = app.switches["monochromeToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        return toggle
    }

    @MainActor
    private func launch(demoPlay: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-PFPreloadFixtures", "-PFMuteOutput", "-PFStage", "deck"]
        if demoPlay { app.launchArguments.append("-PFDemoPlay") }
        app.launch()
        return app
    }

    @MainActor
    private func openShelf(_ app: XCUIApplication) {
        let button = app.buttons["shelfButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }

    /// Taps `button` until `target` shows. The simulator sometimes drops a system banner over the top of the screen
    /// (where the Deck/Cover switch sits) for a few seconds after boot; a second tap lands once it has gone.
    @MainActor
    private func tapUntil(_ button: XCUIElement, shows target: XCUIElement) {
        for _ in 0..<4 {
            button.tap()
            if target.waitForExistence(timeout: 3) { return }
        }
        XCTFail("\(button) never showed \(target)")
    }

    /// m:ss as seconds.
    private static func seconds(_ clock: String) -> Int {
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : 0
    }
}
