import XCTest

/// Settings → Customize deck: the design and record style are saved and survive a relaunch.
final class CustomizeDeckUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Launch arguments would pin the saved values and mask the taps (an argument overrides what the screen writes),
    /// so the test normalises through the UI instead: it starts by choosing the defaults, whatever an earlier run left,
    /// and a teardown block chooses them again, so a failure midway can't leave the app changed.
    @MainActor
    func testCustomizeDeckPersists() {
        let launchArguments = ["-PFPreloadFixtures", "-PFStage", "deck"]
        let app = XCUIApplication.pointFlac(launchArguments)
        app.launch()
        addTeardownBlock { [self] in
            MainActor.assumeIsolated {
                let cleanup = XCUIApplication.pointFlac(launchArguments, freshSound: false)
                cleanup.launch()
                chooseDefaults(cleanup)
            }
        }
        chooseDefaults(app)
        XCTAssertTrue(app.buttons["deckDesign-glasshouse"].isSelected)

        let walnut = app.buttons["deckDesign-walnut"]
        scrollTo(walnut, in: app)
        walnut.tap()
        waitUntilSelected(walnut)

        let picker = app.segmentedControls["recordStylePicker"]
        scrollTo(picker, in: app)
        picker.buttons["Picture disc"].tap()
        XCTAssertTrue(picker.buttons["Picture disc"].isSelected)
        app.terminate()

        let relaunched = XCUIApplication.pointFlac(launchArguments, freshSound: false)
        relaunched.launch()
        openCustomizeDeck(relaunched)
        let persisted = relaunched.buttons["deckDesign-walnut"]
        scrollTo(persisted, in: relaunched)
        XCTAssertTrue(persisted.isSelected)
        let persistedPicker = relaunched.segmentedControls["recordStylePicker"]
        scrollTo(persistedPicker, in: relaunched)
        XCTAssertTrue(persistedPicker.buttons["Picture disc"].isSelected)
        relaunched.terminate()
    }

    /// Opens the screen and chooses Glasshouse and Black vinyl, leaving the screen open.
    @MainActor
    private func chooseDefaults(_ app: XCUIApplication) {
        openCustomizeDeck(app)
        let design = app.buttons["deckDesign-glasshouse"]
        scrollTo(design, in: app)
        design.tap()
        waitUntilSelected(design)
        let picker = app.segmentedControls["recordStylePicker"]
        scrollTo(picker, in: app)
        picker.buttons["Black vinyl"].tap()
        XCTAssertTrue(picker.buttons["Black vinyl"].isSelected)
        // Back to the top, where the Glasshouse card is.
        for _ in 0..<4 { app.swipeDown() }
    }

    /// The trait follows the tap a moment later on a loaded machine.
    @MainActor
    private func waitUntilSelected(_ element: XCUIElement) {
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: element)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    private func openCustomizeDeck(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["shelfButton"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        let link = app.buttons["customizeDeckLink"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
    }

    /// Swipes up until `element` is on screen and clear of the floating tab bar (the grid is longer than the screen).
    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        let tabBar = app.tabBars.firstMatch
        var tries = 0
        while tries < 8 {
            if element.exists && element.isHittable && element.frame.maxY < tabBar.frame.minY { break }
            app.swipeUp()
            tries += 1
        }
        XCTAssertTrue(element.exists)
    }
}
