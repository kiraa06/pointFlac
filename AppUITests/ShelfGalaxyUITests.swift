import XCTest

/// Plan 9's Galaxy mode of the Shelf: every album a floating sleeve, the top of the sort biggest at the centre, a tap
/// plays it with the crate's hand-off.
///
/// Every launch opens the Shelf (`-PFOpenShelf`) on the demo albums in a library of its own (`-PFFreshLibrary`), so no
/// listen history from an earlier run can change the order. The mode and the sort come in through the argument domain
/// (`-shelfMode galaxy`, `-galaxySort …`), which `@AppStorage` reads first: nothing is written, so the next suite still
/// opens on the Crate.
final class ShelfGalaxyUITests: XCTestCase {
    /// What the debug bundle's fixtures list on the shelf: the five demo albums, plus "Fixture Album" (s24-48000) and
    /// "Unknown Album" (the untagged s16-44100 and s32-48000).
    private static let albumCount = 7

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testGalaxyShowsAllAlbumsAndSorts() {
        let app = launch()
        let galaxy = app.descendants(matching: .any)["shelfGalaxy"]
        XCTAssertTrue(galaxy.waitForExistence(timeout: 8))
        let sleeves = galaxy.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'galaxy-'"))
        let all = NSPredicate(format: "count == \(Self.albumCount)")
        expectation(for: all, evaluatedWith: sleeves)
        waitForExpectations(timeout: 8)

        choose("Newest release", in: app)
        XCTAssertTrue(sleeve(0, in: app).waitForExistence(timeout: 3))

        // Hydrophone is the demo library's 32-bit, 96 kHz album; the untagged 32-bit fixture is only 48 kHz.
        choose("Hi-res first", in: app)
        let hydrophone = NSPredicate(format: "label BEGINSWITH 'Hydrophone, '")
        expectation(for: hydrophone, evaluatedWith: sleeve(0, in: app))
        waitForExpectations(timeout: 3)
        XCTAssertEqual(app.buttons["galaxySortMenu"].value as? String, "Hi-res first")
    }

    @MainActor
    func testTappingASleevePlaysIt() {
        // Hi-res first puts Hydrophone at the centre, and its first song is Sonar.
        let app = launch(sort: "hiResFirst")
        let centre = sleeve(0, in: app)
        XCTAssertTrue(centre.waitForExistence(timeout: 8))
        XCTAssertTrue(centre.label.hasPrefix("Hydrophone, "), "galaxy-0 reads \"\(centre.label)\"")
        centre.tap()
        let title = app.staticTexts["nowPlayingTitle"]
        let sonar = NSPredicate(format: "label == 'Sonar'")
        expectation(for: sonar, evaluatedWith: title)
        waitForExpectations(timeout: 6)
    }

    @MainActor
    func testFallbackNoteWithoutHistory() {
        let app = launch(sort: "mostPlayed")
        XCTAssertTrue(app.descendants(matching: .any)["shelfGalaxy"].waitForExistence(timeout: 8))
        let note = app.staticTexts["galaxyFallbackNote"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertEqual(note.label, "No listening history yet. Sized by Last added.")
    }

    /// Holding a sleeve offers the crate's actions. ("Play" is left out of the check: the deck's play button behind
    /// the shelf has the same label.)
    @MainActor
    func testHoldingASleeveOffersTheCratesActions() {
        let app = launch(sort: "hiResFirst")
        let centre = sleeve(0, in: app)
        XCTAssertTrue(centre.waitForExistence(timeout: 8))
        centre.press(forDuration: 1.0)
        for title in ["Play Next", "Add to Up Next", "Delete Album…"] {
            XCTAssertTrue(app.buttons[title].firstMatch.waitForExistence(timeout: 3), "the hold menu has no \(title)")
        }
    }

    /// Spec §2: a dropped sleeve stays where it was dropped; nothing drifts back.
    @MainActor
    func testDraggedSleeveStaysWhereDropped() {
        let app = launch(sort: "hiResFirst")
        let centre = sleeve(0, in: app)
        XCTAssertTrue(centre.waitForExistence(timeout: 8))
        // The galaxy forms first; a drag only starts on a sleeve that has landed.
        Thread.sleep(forTimeInterval: 1.5)
        let before = centre.frame
        let start = centre.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(
            forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 110)), withVelocity: 150,
            thenHoldForDuration: 0.3)
        let moved = NSPredicate { _, _ in centre.frame.midY > before.midY + 70 }
        expectation(for: moved, evaluatedWith: nil)
        waitForExpectations(timeout: 4)
        // Still there a moment later: no spring home.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertGreaterThan(centre.frame.midY, before.midY + 70)
    }

    // MARK: Helpers

    @MainActor
    private func launch(sort: String? = nil) -> XCUIApplication {
        var arguments = ["-PFPreloadFixtures", "-PFFreshLibrary", "-PFOpenShelf", "-shelfMode", "galaxy"]
        if let sort { arguments += ["-galaxySort", sort] }
        let app = XCUIApplication.pointFlac(arguments)
        app.launch()
        return app
    }

    @MainActor
    private func sleeve(_ rank: Int, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["galaxy-\(rank)"]
    }

    /// Opens the sort menu and picks `title` from it.
    @MainActor
    private func choose(_ title: String, in app: XCUIApplication) {
        let menu = app.buttons["galaxySortMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        menu.tap()
        let item = app.buttons[title]
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.tap()
    }
}
