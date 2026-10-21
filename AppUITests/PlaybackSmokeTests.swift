import XCTest

/// The debug app end to end on the simulator, against the fixtures it bundles in Debug builds. Since Plan 3 the debug
/// library and player live under Settings → Diagnostics, so each launch goes there first.
///
/// Every launch passes `-PFMuteOutput`, so nothing plays through the Mac's speakers (ruling R22). The app's library
/// folder outlives a launch, so after the first launch the preload finds duplicates and skips them; the tests look for
/// specific rows, never for counts. Rows are found by file name, because the fixtures' titles are not unique (R20).
///
/// The strip depends on the Mac: the simulator's hardware side is the Mac's output device (R17). So the tests check
/// what follows from the source on any Mac, and the exact strings only when the strip shows no resampling, which is
/// the case at 48 kHz (where S1 records them as verified). On a machine with no usable audio output, a headless CI
/// runner say, the playback tests skip rather than fail.
final class PlaybackSmokeTests: XCTestCase {
    @MainActor
    func testPreloadedFixturePlaysWithHonestStrip() throws {
        let app = launch()
        let strip = try play("s24-48000", in: app)
        XCTAssertTrue(strip.hasPrefix("FLAC · 24-bit · "), "the signal strip reads \"\(strip)\"")
        XCTAssertTrue(strip.contains("●"))
        XCTAssertFalse(strip.localizedCaseInsensitiveContains("bit-perfect"))
        if strip.contains("Resampled") {
            // This Mac's output runs at another rate, so iOS resamples after the unit, and the strip has to say so.
            XCTAssertTrue(strip.contains("● Resampled 48→"), "the signal strip reads \"\(strip)\"")
        } else {
            XCTAssertEqual(strip, "FLAC · 24-bit · 48 kHz · ● Pure")
        }
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
    func testThirtyTwoBitFixtureShowsDepthReduction() throws {
        let app = launch()
        let strip = try play("s32-48000", in: app)
        XCTAssertTrue(strip.hasPrefix("FLAC · 32-bit · "), "the signal strip reads \"\(strip)\"")
        XCTAssertTrue(strip.contains("●"))
        XCTAssertFalse(strip.localizedCaseInsensitiveContains("bit-perfect"))
        if strip.contains("Resampled") {
            // As above. Resampling outranks the depth reduction in `SignalState.indicator`, so the strip shows it.
            XCTAssertTrue(strip.contains("● Resampled 48→"), "the signal strip reads \"\(strip)\"")
        } else {
            XCTAssertEqual(strip, "FLAC · 32-bit · 48 kHz · ● 32→24-bit")
        }
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-PFPreloadFixtures", "-PFMuteOutput"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        let diagnostics = app.buttons["diagnosticsLink"]
        // Diagnostics sits below Privacy and Soulseek, so it may be off screen.
        if !diagnostics.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
        diagnostics.tap()
        return app
    }

    /// The library row for the fixture file `stem`, once the preload has listed it.
    @MainActor
    private func row(_ stem: String, in app: XCUIApplication) -> XCUIElement {
        let row = app.buttons["trackRow-\(stem)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no library row for \(stem)")
        return row
    }

    /// Taps the row for `stem` and returns the strip once it describes the track. Skips when this machine has no
    /// usable audio output: the player could not build one, or could not activate the audio session.
    @MainActor
    private func play(_ stem: String, in app: XCUIApplication) throws -> String {
        let row = row(stem, in: app)
        row.tap()
        let strip = app.staticTexts["signalStrip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 2))
        // The strip reads "No record" until the track is on its way, then "● Starting…" until its pipeline has a plan.
        let begins = NSPredicate(format: "label BEGINSWITH 'FLAC' AND NOT (label CONTAINS 'Starting')")
        let started = XCTNSPredicateExpectation(predicate: begins, object: strip)
        if XCTWaiter.wait(for: [started], timeout: 2) != .completed {
            let status = app.staticTexts["playerStatus"]
            for unavailable in ["Failed: Audio session unavailable", "Failed: Audio output unavailable"]
            where status.exists && status.label.hasPrefix(unavailable) {
                throw XCTSkip("No audio output on this machine: \(status.label)")
            }
            XCTFail("the strip never described \(stem): it reads \"\(strip.label)\", the status \"\(status.label)\"")
        }
        return strip.label
    }
}
