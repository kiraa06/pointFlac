import XCTest

/// Customize deck (plan 10): every design is a working deck, not a picture of one. A DJ deck, a wooden box with a
/// J-arm, and the linear tracker each show the record and the display, and seek when the arm (or the carriage) is
/// dragged across the record. The DJ deck's start/stop button pauses. Each launch picks the design with
/// `-deckDesign`, which `@AppStorage` reads from the arguments domain, and is muted (ruling R22).
final class DeckDesignUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testStudioSilverSeeksAndStartStopPauses() {
        let app = launch("studioSilver")
        assertDeckSeeks(app)
        expectation(for: NSPredicate(format: "label == 'Pause'"), evaluatedWith: app.buttons["playButton"])
        waitForExpectations(timeout: 5)
        let startStop = app.buttons["deckStartStop"]
        XCTAssertTrue(startStop.waitForExistence(timeout: 3))
        XCTAssertEqual(startStop.label, "Start/Stop")
        startStop.tap()
        expectation(for: NSPredicate(format: "label == 'Play'"), evaluatedWith: app.buttons["playButton"])
        waitForExpectations(timeout: 5)
        // Kept in the result bundle for review: the arm lifted off the record, its shadow spread.
        Thread.sleep(forTimeInterval: 1)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "studioSilver-paused"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testWalnutSeeks() {
        let app = launch("walnut")
        assertDeckSeeks(app)
        // Only the DJ layouts have a working start/stop; the walnut box's furniture is decorative.
        XCTAssertFalse(app.buttons["deckStartStop"].exists)
    }

    @MainActor
    func testLinearCarriageSeeks() {
        let app = launch("linear")
        assertDeckSeeks(app)
    }

    // MARK: Helpers

    /// The record and the display are there, and dragging the arm (or the carriage) well into the side moves the
    /// music: another song, or far into the first.
    @MainActor
    private func assertDeckSeeks(_ app: XCUIApplication) {
        let title = app.staticTexts["nowPlayingTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        XCTAssertEqual(title.label, "Ignition")
        let record = app.descendants(matching: .any)["deckRecord"]
        let display = app.descendants(matching: .any)["deckDisplay"]
        let handle = app.descendants(matching: .any)["tonearmHandle"]
        XCTAssertTrue(record.waitForExistence(timeout: 3))
        XCTAssertTrue(display.exists)
        XCTAssertTrue(handle.waitForExistence(timeout: 3))
        let elapsed = app.staticTexts["elapsedTime"]
        let before = Self.seconds(elapsed.label)
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // Right of the spindle and a little below it: the pivoted arms swing there along their arc, and the carriage
        // slides to its projection on the rail; either way about two thirds into side A, clear of the side's end.
        let end = record.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.6))
        start.press(forDuration: 0.3, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        let moved = NSPredicate { _, _ in
            title.label != "Ignition" || Self.seconds(elapsed.label) >= max(20, before + 15)
        }
        expectation(for: moved, evaluatedWith: nil)
        waitForExpectations(timeout: 6)
    }

    @MainActor
    private func launch(_ design: String) -> XCUIApplication {
        let app = XCUIApplication.pointFlac([
            "-PFPreloadFixtures", "-PFStage", "deck", "-PFDemoPlay", "-deckDesign", design,
        ])
        app.launch()
        return app
    }

    /// m:ss as seconds.
    private static func seconds(_ clock: String) -> Int {
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : 0
    }
}
