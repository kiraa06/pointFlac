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

    /// The bundled licence notice is one tap away, and carries libFLAC's BSD notice and pointFlac's MIT licence.
    @MainActor
    func testLicencesShowTheBundledNotices() {
        let app = XCUIApplication()
        app.launchArguments = ["-PFMuteOutput"]
        app.launch()
        let link = app.buttons["licencesLink"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        let notices = app.staticTexts["licenceNotices"]
        XCTAssertTrue(notices.waitForExistence(timeout: 5))
        XCTAssertTrue(notices.label.contains("Xiph.Org Foundation"), "the notice: \(notices.label.prefix(200))")
        XCTAssertTrue(notices.label.contains("Redistributions in binary form must reproduce the above copyright"))
        XCTAssertTrue(notices.label.contains("MIT License"))
        XCTAssertTrue(notices.label.contains("Copyright (c) 2026 Kiran P Jose"))
    }
}
