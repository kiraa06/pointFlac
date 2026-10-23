import XCTest

/// Settings → Customize deck: the design and record style are saved and survive a relaunch.
final class CustomizeDeckUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testCustomizeDeckPersists() {
        let app = XCUIApplication.pointFlac(["-PFPreloadFixtures", "-PFStage", "deck"])
        app.launch()
        openCustomizeDeck(app)

        let walnut = app.buttons["deckDesign-walnut"]
        scrollTo(walnut, in: app)
        walnut.tap()
        XCTAssertTrue(walnut.isSelected)

        let picker = app.segmentedControls["recordStylePicker"]
        scrollTo(picker, in: app)
        picker.buttons["Picture disc"].tap()
        XCTAssertTrue(picker.buttons["Picture disc"].isSelected)
        app.terminate()

        let relaunched = XCUIApplication.pointFlac(["-PFPreloadFixtures", "-PFStage", "deck"], freshSound: false)
        relaunched.launch()
        openCustomizeDeck(relaunched)
        let persisted = relaunched.buttons["deckDesign-walnut"]
        scrollTo(persisted, in: relaunched)
        XCTAssertTrue(persisted.isSelected)
        let persistedPicker = relaunched.segmentedControls["recordStylePicker"]
        scrollTo(persistedPicker, in: relaunched)
        XCTAssertTrue(persistedPicker.buttons["Picture disc"].isSelected)

        // Leave the app as found.
        persistedPicker.buttons["Black vinyl"].tap()
        let original = relaunched.buttons["deckDesign-glasshouse"]
        scrollTo(original, in: relaunched)
        original.tap()
    }

    @MainActor
    private func openCustomizeDeck(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["shelfButton"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        let link = app.buttons["customizeDeckLink"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
    }

    /// Swipes up until `element` is on screen (the grid is longer than the screen).
    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        var tries = 0
        while !element.isHittable && tries < 8 {
            app.swipeUp()
            tries += 1
        }
        XCTAssertTrue(element.exists)
    }
}
