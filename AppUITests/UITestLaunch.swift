import XCTest

extension XCUIApplication {
    /// pointFlac set up for a UI test, not yet launched: muted (ruling R22), with `arguments` after, and, unless
    /// `freshSound` is false, starting from the Pure defaults. `-PFResetSound` (DEBUG) deletes the saved Sound settings
    /// (`sound.json`) and the remembered ReplayGain and crossfade modes at launch, so what an earlier run, a screenshot
    /// session or a manual session left behind can't decide what the strip says. A relaunch that tests persistence
    /// passes `freshSound: false`.
    @MainActor
    static func pointFlac(_ arguments: [String] = [], freshSound: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-PFMuteOutput"] + (freshSound ? ["-PFResetSound"] : []) + arguments
        return app
    }
}
