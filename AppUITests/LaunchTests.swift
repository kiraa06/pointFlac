import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testAppShowsTitle() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["pointFlac"].waitForExistence(timeout: 5))
    }
}
