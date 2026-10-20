import XCTest

/// The debug app end to end on the simulator, against the fixtures it bundles in Debug builds.
///
/// Every launch passes `-PFMuteOutput`, so nothing plays through the Mac's speakers (ruling R22). The app's library
/// folder outlives a launch, so after the first launch the preload finds duplicates and skips them; the tests look for
/// specific rows, never for counts. Rows are found by file name, because the fixtures' titles are not unique (R20).
final class PlaybackSmokeTests: XCTestCase {
    @MainActor
    func testPreloadedFixturePlaysWithHonestStrip() {
        let app = launch()
        row("s24-48000", in: app).tap()
        let strip = app.staticTexts["signalStrip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 2))
        // The strip reads "No record" until the track starts. The simulator's hardware side runs at 48 kHz (R17), so
        // a 48 kHz source plays untouched.
        XCTAssertTrue(
            strip.wait(for: \.label, toEqual: "FLAC · 24-bit · 48 kHz · ● Pure", timeout: 2),
            "the signal strip reads \"\(strip.label)\"")
        XCTAssertTrue(strip.label.hasPrefix("FLAC · 24-bit · "))
        XCTAssertTrue(strip.label.contains("●"))
        XCTAssertFalse(strip.label.localizedCaseInsensitiveContains("bit-perfect"))
    }

    @MainActor
    func testDisguisedMP3IsNotListed() {
        let app = launch()
        // Once a valid fixture's row is there, the import has finished.
        _ = row("s24-48000", in: app)
        XCTAssertFalse(app.descendants(matching: .any)["trackRow-renamed-mp3"].exists)
        XCTAssertTrue(app.staticTexts["Not a FLAC file"].waitForExistence(timeout: 2))
    }

    /// Ruling R21: a 32-bit source is TPDF-reduced to 24 bits, because `OutputCapabilities.current` claims no Int32
    /// passthrough (R13), and the strip says so.
    @MainActor
    func testThirtyTwoBitFixtureShowsDepthReduction() {
        let app = launch()
        row("s32-48000", in: app).tap()
        let strip = app.staticTexts["signalStrip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 2))
        XCTAssertTrue(
            strip.wait(for: \.label, toEqual: "FLAC · 32-bit · 48 kHz · ● 32→24-bit", timeout: 2),
            "the signal strip reads \"\(strip.label)\"")
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-PFPreloadFixtures", "-PFMuteOutput"]
        app.launch()
        return app
    }

    /// The library row for the fixture file `stem`, once the preload has listed it.
    @MainActor
    private func row(_ stem: String, in app: XCUIApplication) -> XCUIElement {
        let row = app.buttons["trackRow-\(stem)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no library row for \(stem)")
        return row
    }
}
