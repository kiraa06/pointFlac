import XCTest

/// Settings → Downloads: downloads saved to a folder the user picked in Files survive pointFlac being deleted, and a
/// download is never lost when that folder can't be reached.
///
/// The document picker can't be driven from a test, so `-PFDownloadFolder <path>` (DEBUG) stands in for a pick: a
/// plain folder, no bookmark. On the simulator the app can write into the test runner's temporary folder, so the test
/// checks the file itself. With that argument the demo finder (`-PFMockFinder`) publishes a real demo song, Ada
/// Vale's "Fold" from Paper Moons, through the app's own publish step. `-PFFreshLibrary` starts from an empty shelf.
final class DownloadFolderUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testDownloadFolderSettingShowsDefault() {
        let app = XCUIApplication.pointFlac(["-PFMockFinder", "-PFResetDownloadFolder"])
        app.launch()
        let link = openDownloadsSetting(app)
        XCTAssertTrue(link.label.contains("Save downloads to"), "the row: \(link.label)")
        XCTAssertTrue(link.label.contains("pointFlac"), "the row: \(link.label)")

        link.tap()
        let inApp = app.buttons["downloadDestinationApp"]
        XCTAssertTrue(inApp.waitForExistence(timeout: 3))
        XCTAssertTrue(inApp.isSelected)
        XCTAssertTrue(app.buttons["downloadDestinationFolder"].exists)
        XCTAssertFalse(app.buttons["downloadDestinationChange"].exists)
        let footer = NSPredicate(format: "label BEGINSWITH 'Songs saved to a folder you choose stay there'")
        XCTAssertTrue(app.staticTexts.matching(footer).firstMatch.exists)
    }

    /// A download lands at <Artist>/<Album>/ in the chosen folder, the shelf shows its album, and deleting it from
    /// pointFlac says the file stays, and leaves it there.
    @MainActor
    func testDownloadsGoToTheChosenFolder() throws {
        let folder = try makeFolder()
        let app = XCUIApplication.pointFlac(["-PFMockFinder", "-PFFreshLibrary", "-PFDownloadFolder", folder.path])
        app.launch()

        let link = openDownloadsSetting(app)
        XCTAssertTrue(link.label.contains(folder.lastPathComponent), "the row: \(link.label)")

        let row = download(app)
        expectation(for: NSPredicate(format: "label CONTAINS 'Done'"), evaluatedWith: row)
        waitForExpectations(timeout: 15)
        XCTAssertFalse(row.label.contains("folder unavailable"), "the row: \(row.label)")
        let saved = folder.appending(path: "Ada Vale/Paper Moons/01 Fold.flac")
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path), "nothing at \(saved.path)")

        let album = findOnShelf(app, "Paper Moons")
        album.press(forDuration: 1.2)
        let delete = app.buttons["Delete Album…"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        // The folder is read in place: the song leaves pointFlac, and its file stays.
        let remove = app.buttons["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Removes 1 song from pointFlac. The file stays in its folder."].exists)
        remove.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: album)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
    }

    /// The folder disappears after launch: the download still finishes, in the app, its row says so, and Settings
    /// shows the folder as unavailable with a way to choose it again.
    @MainActor
    func testDownloadFallsBackWhenTheFolderIsUnreachable() throws {
        let folder = try makeFolder()
        let app = XCUIApplication.pointFlac(["-PFMockFinder", "-PFFreshLibrary", "-PFDownloadFolder", folder.path])
        app.launch()
        XCTAssertTrue(app.buttons["shelfButton"].waitForExistence(timeout: 5))
        try FileManager.default.removeItem(at: folder)

        let row = download(app)
        expectation(
            for: NSPredicate(format: "label CONTAINS 'Saved in pointFlac (folder unavailable)'"), evaluatedWith: row)
        waitForExpectations(timeout: 15)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "the folder was made again")

        let link = openDownloadsSetting(app)
        XCTAssertTrue(link.label.contains("Unavailable"), "the row: \(link.label)")
        link.tap()
        XCTAssertTrue(app.descendants(matching: .any)["downloadFolderUnavailable"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["downloadDestinationChooseAgain"].exists)

        // The song was saved in the app, so it is on the shelf all the same.
        _ = findOnShelf(app, "Paper Moons")
    }

    // MARK: Helpers

    /// A new folder in the test runner's temporary folder, removed when the test ends.
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "Downloads-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    @MainActor
    private func openDownloadsSetting(_ app: XCUIApplication) -> XCUIElement {
        app.tabBars.buttons["Settings"].tap()
        let link = app.buttons["downloadFolderLink"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        return link
    }

    /// Downloads the demo finder's first Internet Archive result and returns its Downloads row.
    @MainActor
    private func download(_ app: XCUIApplication) -> XCUIElement {
        app.tabBars.buttons["Get Music"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("test\n")
        let download = app.buttons["download-ia-Test-1"]
        XCTAssertTrue(download.waitForExistence(timeout: 4))
        download.tap()
        app.tabBars.buttons["Downloads"].tap()
        let row = app.descendants(matching: .any)["downloadRow-ia-Test-1"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        return row
    }

    /// Opens the shelf and searches it for `album`, returning its result.
    @MainActor
    private func findOnShelf(_ app: XCUIApplication, _ album: String) -> XCUIElement {
        app.tabBars.buttons["Player"].tap()
        let shelf = app.buttons["shelfButton"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 5))
        shelf.tap()
        let field = app.textFields["shelfSearch"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText(album.lowercased())
        let result = app.buttons["result-album-\(album)"]
        XCTAssertTrue(result.waitForExistence(timeout: 5), "\(album) is not on the shelf")
        return result
    }
}
