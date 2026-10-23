import XCTest

/// Customize deck (plan 10): every design is a working deck, not a picture of one. A DJ deck, a wooden box with a
/// J-arm, and the linear tracker each say which turntable they are, show the record and the display with the arm
/// where that design puts it, and seek when the arm (or the carriage) is dragged across the record. The DJ deck's
/// start/stop button pauses, and the arm never takes a tap meant for the record beside it. Each launch picks the design with
/// `-deckDesign`, which `@AppStorage` reads from the arguments domain, and is muted (ruling R22).
final class DeckDesignUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testStudioSilverSeeksAndStartStopPauses() {
        let app = launch("studioSilver")
        assertDesign(app, "Studio Silver")
        assertPivotedArmOnTheLeadIn(app)
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
        assertDesign(app, "Walnut")
        assertPivotedArmOnTheLeadIn(app)
        assertDeckSeeks(app)
        // Only the DJ layouts have a working start/stop; the walnut box's furniture is decorative.
        XCTAssertFalse(app.buttons["deckStartStop"].exists)
    }

    @MainActor
    func testLinearCarriageSeeks() {
        let app = launch("linear")
        assertDesign(app, "Linear")
        // The carriage rides the 3 o'clock radius: its handle sits on the line through the spindle, right of it, at
        // the rim. A pivoted arm's headshell would sit well below that line, on its arc.
        let record = app.descendants(matching: .any)["deckRecord"]
        let handle = app.descendants(matching: .any)["tonearmHandle"]
        XCTAssertTrue(record.waitForExistence(timeout: 8) && handle.waitForExistence(timeout: 3))
        XCTAssertLessThan(abs(handle.frame.midY - record.frame.midY), record.frame.height * 0.1)
        XCTAssertGreaterThan(handle.frame.midX, record.frame.midX + record.frame.width * 0.35)
        assertDeckSeeks(app)
        // Seeking slid it straight in along the same line.
        XCTAssertLessThan(abs(handle.frame.midY - record.frame.midY), record.frame.height * 0.1)
        XCTAssertLessThan(handle.frame.midX, record.frame.midX + record.frame.width * 0.35)
    }

    /// A tap on the paused record just beside the tonearm's tube turns the record over: the arm takes only touches on
    /// itself. Dropping the needle afterwards then plays side B. (Were the tap taken by the arm, it would drop the
    /// needle on side A at once.)
    @MainActor
    func testTapBesideTheTubeTurnsThePausedRecordOver() {
        // A straight arm, so its tube runs straight from the pivot.
        let app = launch("bauhausWhite")
        assertDesign(app, "Bauhaus White")
        // Well into side A, so the tube lies across the record.
        assertDeckSeeks(app)
        let play = app.buttons["playButton"]
        play.tap()
        expectation(for: NSPredicate(format: "label == 'Play'"), evaluatedWith: play)
        waitForExpectations(timeout: 5)
        let record = app.descendants(matching: .any)["deckRecord"].frame
        let grip = app.descendants(matching: .any)["tonearmHandle"].frame
        // The pivot, from the deck's proportions: 1.45 record radii from the spindle, 28° above the line across.
        let r = record.width / 2
        let tilt = 28.0 * Double.pi / 180
        let pivot = CGPoint(x: record.midX + 1.45 * r * cos(tilt), y: record.midY - 1.45 * r * sin(tilt))
        let hand = CGPoint(x: grip.midX, y: grip.midY)
        // The arm's angle (0 hangs straight down, positive swings in) and, 70 % of the way along it, a spot 10 pt to
        // the spindle's side: on the record, a finger's width from the tube.
        let angle = atan2(pivot.x - hand.x, hand.y - pivot.y)
        let spot = CGPoint(
            x: pivot.x + 0.7 * (hand.x - pivot.x) - 10 * cos(angle),
            y: pivot.y + 0.7 * (hand.y - pivot.y) - 10 * sin(angle))
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: spot.x, dy: spot.y)).tap()
        // Let the record finish turning over, then drop the needle on the side now up.
        Thread.sleep(forTimeInterval: 1.2)
        app.descendants(matching: .any)["tonearmHandle"].tap()
        let title = app.staticTexts["nowPlayingTitle"]
        expectation(for: NSPredicate(format: "label == 'Tail Lights'"), evaluatedWith: title)
        waitForExpectations(timeout: 6)
    }

    // MARK: Helpers

    /// The deck says which turntable it is: the design took effect.
    @MainActor
    private func assertDesign(_ app: XCUIApplication, _ name: String) {
        let stage = app.descendants(matching: .any)["deckStage"]
        XCTAssertTrue(stage.waitForExistence(timeout: 8))
        XCTAssertEqual(stage.label, "\(name) turntable")
    }

    /// A pivoted arm at the start of the side: its headshell on the lead-in, below and right of the spindle, where the
    /// arm's arc from the rear-right pivot crosses the rim (a linear carriage would sit on the line through the
    /// spindle).
    @MainActor
    private func assertPivotedArmOnTheLeadIn(_ app: XCUIApplication) {
        let record = app.descendants(matching: .any)["deckRecord"]
        let handle = app.descendants(matching: .any)["tonearmHandle"]
        XCTAssertTrue(record.waitForExistence(timeout: 8) && handle.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(handle.frame.midY, record.frame.midY + record.frame.height * 0.2)
        XCTAssertGreaterThan(handle.frame.midX, record.frame.midX + record.frame.width * 0.2)
    }

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
