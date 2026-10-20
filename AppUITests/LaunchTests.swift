import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testAppShowsTitle() {
        let app = XCUIApplication()
        // Like every UI test, muted (ruling R22), though this one plays nothing.
        app.launchArguments = ["-PFMuteOutput"]
        app.launch()
        XCTAssertTrue(app.staticTexts["pointFlac"].waitForExistence(timeout: 5))
    }
}
