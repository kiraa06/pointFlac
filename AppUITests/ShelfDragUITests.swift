import XCTest

/// The owner's bug: the shelf ignored where the finger went. Any drag up from the player carried it all the way open,
/// and any pull down on its grabber all the way closed, however short. Now the panel follows the finger and settles only
/// when it lifts: let go past halfway and it goes on, short of it and it goes back. A quick flick goes the way it
/// points.
///
/// The slow drags here hold still before the finger lifts, so no flick decides them, only where the panel was let go.
/// Every launch starts on a library of its own (`-PFFreshLibrary`) with nothing playing, so the player shows its
/// "Swipe up" line, which has no gesture of its own: the drags up start there.
final class ShelfDragUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testShortDragUpReleasedEarlyLeavesTheShelfClosed() {
        let app = launch()
        let start = swipeLine(app)
        drag(from: start, by: -Self.short(app))
        XCTAssertTrue(field(app).waitForNonExistence(timeout: 5), "a short drag up opened the shelf all the way")
        XCTAssertTrue(app.buttons["shelfButton"].isHittable)
    }

    @MainActor
    func testLongDragUpOpensTheShelf() {
        let app = launch()
        let start = swipeLine(app)
        drag(from: start, by: -Self.long(app))
        XCTAssertTrue(field(app).waitForExistence(timeout: 5), "a long drag up left the shelf closed")
        // It settles open and stays there.
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(field(app).isHittable)
    }

    @MainActor
    func testQuickFlickUpOpensTheShelf() {
        let app = launch()
        let start = swipeLine(app)
        start.press(
            forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -Self.short(app))), withVelocity: 1800,
            thenHoldForDuration: 0)
        XCTAssertTrue(field(app).waitForExistence(timeout: 5), "a quick flick up left the shelf closed")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(field(app).isHittable)
    }

    @MainActor
    func testShortDragDownOnTheGrabberLeavesTheShelfOpen() {
        let app = launch(open: true)
        let search = field(app)
        XCTAssertTrue(search.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 0.6)
        let openTop = search.frame.minY
        drag(from: grabber(app), by: Self.short(app))
        // Back where it was, and still there.
        let home = NSPredicate { _, _ in search.exists && abs(search.frame.minY - openTop) < 2 }
        expectation(for: home, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(search.exists, "a short pull down closed the shelf all the way")
        XCTAssertEqual(search.frame.minY, openTop, accuracy: 2)
    }

    @MainActor
    func testLongDragDownOnTheGrabberClosesTheShelf() {
        let app = launch(open: true)
        XCTAssertTrue(field(app).waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 0.6)
        drag(from: grabber(app), by: Self.long(app))
        XCTAssertTrue(field(app).waitForNonExistence(timeout: 5), "a long pull down left the shelf open")
        XCTAssertTrue(app.buttons["shelfButton"].isHittable)
    }

    /// The grabber's touch zone is 44 pt tall without the header growing: it reaches above the panel's top edge, so a
    /// pull that starts just above the shelf takes it rather than the deck under it.
    @MainActor
    func testPullFromJustAboveTheShelfTakesTheGrabber() {
        let app = launch(open: true)
        XCTAssertTrue(field(app).waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 0.6)
        let grabber = app.buttons["Close the shelf"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 3))
        // The grabber's top is the panel's top edge: start 12 pt above it.
        let start = grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(
            CGVector(dx: 0, dy: -12))
        drag(from: start, by: Self.long(app))
        XCTAssertTrue(field(app).waitForNonExistence(timeout: 5), "a pull from just above the shelf left it open")
    }

    /// The deck's unfolded tracklist takes the stage: a drag up on it is the list's, never the shelf's, whether it is
    /// long and slow (which would carry the shelf open) or a quick flick. Night Drive's five songs fit the panel at the
    /// default text size, so here the list has nowhere to scroll and the drag reaches nothing else.
    @MainActor
    func testDragUpOnTheDeckTracklistLeavesTheShelfClosed() {
        let app = launchOnTheDeckTracklist()
        let list = app.descendants(matching: .any)["deckTracklist"]
        dragUp(on: list, in: app)
        XCTAssertTrue(list.exists)
        XCTAssertTrue(app.buttons["shelfButton"].isHittable)
    }

    /// At a large text size the same songs run past the panel's edge: a drag up scrolls them, and still leaves the
    /// shelf alone.
    @MainActor
    func testDragUpOnALongDeckTracklistScrollsItAndLeavesTheShelfClosed() {
        let app = launchOnTheDeckTracklist([
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL",
        ])
        let list = app.descendants(matching: .any)["deckTracklist"]
        let first = app.descendants(matching: .any)["deckTrack-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        let top = first.frame.minY
        dragUp(on: list, in: app)
        // The songs went up instead.
        XCTAssertLessThan(first.frame.minY, top - 20, "the deck's tracklist did not scroll")
        XCTAssertTrue(app.buttons["shelfButton"].isHittable)
    }

    // MARK: Helpers

    /// Well short of halfway: the shelf's travel is about three quarters of the screen.
    @MainActor
    private static func short(_ app: XCUIApplication) -> CGFloat { app.windows.firstMatch.frame.height * 0.13 }

    /// Well past halfway.
    @MainActor
    private static func long(_ app: XCUIApplication) -> CGFloat { app.windows.firstMatch.frame.height * 0.5 }

    /// Night Drive playing, with the deck's display unfolded into its tracklist (`-PFTracklist deck`).
    @MainActor
    private func launchOnTheDeckTracklist(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.pointFlac(
            ["-PFPreloadFixtures", "-PFFreshLibrary", "-PFStage", "deck", "-PFDemoPlay", "-PFTracklist", "deck"] + extra
        )
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["deckTracklist"].waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 0.6)
        return app
    }

    /// A long, slow drag up from low on `list`, then a quick flick up: neither may open the shelf.
    @MainActor
    private func dragUp(on list: XCUIElement, in app: XCUIApplication) {
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        drag(from: start, by: -Self.long(app))
        XCTAssertFalse(field(app).waitForExistence(timeout: 2), "a drag up on the deck's tracklist opened the shelf")
        start.press(
            forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -Self.short(app))), withVelocity: 1800,
            thenHoldForDuration: 0)
        XCTAssertFalse(field(app).waitForExistence(timeout: 2), "a flick up on the deck's tracklist opened the shelf")
    }

    @MainActor
    private func launch(open: Bool = false) -> XCUIApplication {
        let arguments = ["-PFPreloadFixtures", "-PFFreshLibrary", "-PFStage", "deck"] + (open ? ["-PFOpenShelf"] : [])
        let app = XCUIApplication.pointFlac(arguments)
        app.launch()
        return app
    }

    @MainActor
    private func field(_ app: XCUIApplication) -> XCUIElement {
        app.textFields["shelfSearch"]
    }

    /// The player's "Swipe up for the shelf" line, centred.
    @MainActor
    private func swipeLine(_ app: XCUIApplication) -> XCUICoordinate {
        let line = app.staticTexts["Swipe up for the shelf and pick a record."]
        // Long enough for a loaded simulator to build the library.
        XCTAssertTrue(line.waitForExistence(timeout: 20))
        XCTAssertFalse(field(app).exists)
        return line.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }

    /// The shelf's grabber, centred.
    @MainActor
    private func grabber(_ app: XCUIApplication) -> XCUICoordinate {
        let grabber = app.buttons["Close the shelf"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 3))
        return grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }

    /// A slow vertical drag by `distance` (negative is up), held still before the finger lifts.
    @MainActor
    private func drag(from start: XCUICoordinate, by distance: CGFloat) {
        start.press(
            forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)), withVelocity: 300,
            thenHoldForDuration: 0.5)
    }
}
