import XCTest

/// Kiran's request: pause, resume and cancel downloads, take a finished one off the list, and delete its song.
///
/// The demo finder (`-PFMockFinder`) simulates the transfers; `-PFSlowDownloads` (DEBUG) stretches each one to about
/// half a minute, so a test can catch it under way. With `-PFDownloadFolder <path>` the demo publishes a real song, Ada
/// Vale's "Fold" from Paper Moons, into that plain folder, where the test can check the file itself.
/// `-PFFreshLibrary` starts from an empty shelf.
final class DownloadControlsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The row's own buttons: Pause and Cancel while it downloads, Resume once paused (continuing where it stopped),
    /// Retry and Remove once cancelled.
    @MainActor
    func testPauseResumeCancelFromTheRow() {
        let app = XCUIApplication.pointFlac(["-PFMockFinder", "-PFSlowDownloads"])
        app.launch()
        let row = download(app, "ia-Test-1")
        wait(for: row, "label CONTAINS 'Downloading'", timeout: 6)
        let pause = app.buttons["downloadPause-ia-Test-1"]
        XCTAssertTrue(pause.waitForExistence(timeout: 3))
        XCTAssertEqual(pause.label, "Pause")
        XCTAssertTrue(app.buttons["downloadCancel-ia-Test-1"].exists)
        // A step or two in, so there is progress to keep.
        wait(for: row, "label CONTAINS 'Downloading' AND NOT (label CONTAINS ' · 0%')", timeout: 6)

        pause.tap()
        wait(for: row, "label CONTAINS 'Paused'", timeout: 3)
        let pausedAt = Self.percent(row.label)
        XCTAssertNotNil(pausedAt, "the paused row keeps its progress: \(row.label)")
        let resume = app.buttons["downloadResume-ia-Test-1"]
        XCTAssertTrue(resume.waitForExistence(timeout: 3))
        XCTAssertEqual(resume.label, "Resume")
        XCTAssertFalse(app.buttons["downloadPause-ia-Test-1"].exists)
        XCTAssertTrue(app.buttons["downloadCancel-ia-Test-1"].exists)
        // Paused stays paused.
        sleep(2)
        XCTAssertTrue(row.label.contains("Paused"), row.label)

        resume.tap()
        wait(for: row, "label CONTAINS 'Downloading'", timeout: 4)
        let resumedAt = Self.percent(row.label)
        XCTAssertGreaterThanOrEqual(resumedAt ?? -1, pausedAt ?? 0, "it continues, not from zero: \(row.label)")

        app.buttons["downloadCancel-ia-Test-1"].tap()
        wait(for: row, "label CONTAINS 'Cancelled'", timeout: 3)
        XCTAssertTrue(app.buttons["downloadRetry-ia-Test-1"].waitForExistence(timeout: 3))
        let remove = app.buttons["downloadRemove-ia-Test-1"]
        XCTAssertTrue(remove.exists)
        remove.tap()
        wait(for: row, "exists == false", timeout: 3)
    }

    /// The toolbar's menu pauses every download at once and resumes them; Cancel All asks first.
    @MainActor
    func testPauseAllAndResumeAll() {
        let app = XCUIApplication.pointFlac(["-PFMockFinder", "-PFSlowDownloads"])
        app.launch()
        let first = download(app, "ia-Test-1")
        let second = download(app, "ia-Test-2", searched: true)
        for row in [first, second] { wait(for: row, "label CONTAINS 'Downloading'", timeout: 6) }

        openMenu(app, choosing: "pauseAll")
        for row in [first, second] { wait(for: row, "label CONTAINS 'Paused'", timeout: 3) }
        XCTAssertTrue(app.buttons["downloadResume-ia-Test-1"].exists)
        XCTAssertTrue(app.buttons["downloadResume-ia-Test-2"].exists)

        openMenu(app, choosing: "resumeAll")
        for row in [first, second] { wait(for: row, "label CONTAINS 'Downloading'", timeout: 4) }

        openMenu(app, choosing: "cancelAll")
        let confirm = app.buttons["Cancel All Downloads"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "Cancel All asks first")
        confirm.tap()
        for row in [first, second] { wait(for: row, "label CONTAINS 'Cancelled'", timeout: 3) }
    }

    /// A finished download's song lives in the download folder, so Delete Song… says it moves to Recently Deleted, and
    /// does it: the file leaves the folder, the album leaves the shelf, and the row goes.
    ///
    /// The simulator has no Recently Deleted (`trashItem` fails on its volumes, Cocoa error 3328), so `-PFTrashFolder`
    /// stands in for it; `testDeleteDownloadedSongKeepsTheFileWhenItCannotBeTrashed` runs the real call.
    @MainActor
    func testDeleteDownloadedSongMovesItOutOfTheFolder() throws {
        let folder = try makeFolder()
        let bin = try makeFolder()
        let app = XCUIApplication.pointFlac([
            "-PFMockFinder", "-PFFreshLibrary", "-PFDownloadFolder", folder.path, "-PFTrashFolder", bin.path,
        ])
        app.launch()
        let row = download(app, "ia-Test-1")
        wait(for: row, "label CONTAINS 'Done'", timeout: 15)
        let saved = folder.appending(path: "Ada Vale/Paper Moons/01 Fold.flac")
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path), "nothing at \(saved.path)")
        // A finished row has no buttons of its own: Delete lives in the long-press menu.
        XCTAssertFalse(app.buttons["downloadRemove-ia-Test-1"].exists)

        row.press(forDuration: 1.2)
        let delete = app.buttons["Delete Song…"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Remove from List"].exists)
        delete.tap()
        let message = "Moves this song to Recently Deleted in Files. You can restore it there for 30 days."
        XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 3))
        // iOS 26 lists each of a dialog's buttons twice, at the same place.
        let confirm = app.buttons["deleteDownloadedSong"].firstMatch
        XCTAssertTrue(confirm.exists)
        XCTAssertEqual(confirm.label, "Delete Song")
        confirm.tap()

        wait(for: row, "exists == false", timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path), "the file is still in the folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bin.appending(path: "01 Fold.flac").path))
        XCTAssertFalse(app.descendants(matching: .any)["downloadsNote"].exists, "the move was reported as failed")
        XCTAssertFalse(isOnShelf(app, "Paper Moons"), "the album is still on the shelf")
    }

    /// The real move to Recently Deleted, which the simulator refuses: the file is never deleted. It stays in the
    /// folder, the song leaves pointFlac as for any folder read in place, and the list says so.
    @MainActor
    func testDeleteDownloadedSongKeepsTheFileWhenItCannotBeTrashed() throws {
        let folder = try makeFolder()
        let app = XCUIApplication.pointFlac(["-PFMockFinder", "-PFFreshLibrary", "-PFDownloadFolder", folder.path])
        app.launch()
        let row = download(app, "ia-Test-1")
        wait(for: row, "label CONTAINS 'Done'", timeout: 15)
        let saved = folder.appending(path: "Ada Vale/Paper Moons/01 Fold.flac")

        row.press(forDuration: 1.2)
        let delete = app.buttons["Delete Song…"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        let confirm = app.buttons["deleteDownloadedSong"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()

        let note = app.staticTexts["Couldn't move the file to Recently Deleted. It stays in its folder."]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertFalse(row.exists)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path), "a file that would not move was deleted")
        XCTAssertFalse(isOnShelf(app, "Paper Moons"), "the album is still on the shelf")
    }

    /// Review fix: a download folder that can't be reached is not treated as the download folder. Deleting its song
    /// says the file stays, removes the song from pointFlac only, and the song does not come back with the folder.
    @MainActor
    func testDeletingFromAnUnavailableDownloadFolderKeepsTheFile() throws {
        let folder = try makeFolder()
        let bin = try makeFolder()
        let app = XCUIApplication.pointFlac([
            "-PFMockFinder", "-PFFreshLibrary", "-PFDownloadFolder", folder.path, "-PFTrashFolder", bin.path,
        ])
        app.launch()
        let row = download(app, "ia-Test-1")
        wait(for: row, "label CONTAINS 'Done'", timeout: 15)
        let saved = folder.appending(path: "Ada Vale/Paper Moons/01 Fold.flac")
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))

        // The folder goes away; back in the app, the check finds it unavailable.
        let away = folder.deletingLastPathComponent().appending(
            path: folder.lastPathComponent + "-away", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: folder, to: away)
        addTeardownBlock { try? FileManager.default.removeItem(at: away) }
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let link = app.buttons["downloadFolderLink"]
        open(app, tab: "Settings", showing: link)
        wait(for: link, "label CONTAINS 'Unavailable'", timeout: 10)
        app.tabBars.buttons["Downloads"].tap()

        row.press(forDuration: 1.2)
        let delete = app.buttons["Delete Song…"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        let message = "Removes this song from pointFlac. The file stays in its folder."
        XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 3), "the dialog promised something else")
        let confirm = app.buttons["deleteDownloadedSong"].firstMatch
        XCTAssertEqual(confirm.label, "Remove Song")
        confirm.tap()
        wait(for: row, "exists == false", timeout: 5)

        // The folder comes back: the song stays out of pointFlac, and its file is where it was.
        try FileManager.default.moveItem(at: away, to: folder)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path), "the file left the folder")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bin.path), [], "something was trashed")
        XCTAssertFalse(isOnShelf(app, "Paper Moons"), "the song came back with its folder")
    }

    /// Remove from List takes the row only: the song stays on the shelf, and its file in the folder.
    @MainActor
    func testRemoveFromListKeepsTheSong() throws {
        let folder = try makeFolder()
        let app = XCUIApplication.pointFlac(["-PFMockFinder", "-PFFreshLibrary", "-PFDownloadFolder", folder.path])
        app.launch()
        let row = download(app, "ia-Test-1")
        wait(for: row, "label CONTAINS 'Done'", timeout: 15)

        row.press(forDuration: 1.2)
        let remove = app.buttons["Remove from List"]
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        remove.tap()

        wait(for: row, "exists == false", timeout: 3)
        let saved = folder.appending(path: "Ada Vale/Paper Moons/01 Fold.flac")
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
        XCTAssertTrue(isOnShelf(app, "Paper Moons"), "the album left the shelf")
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
    private func wait(for element: XCUIElement, _ predicate: String, timeout: TimeInterval) {
        expectation(for: NSPredicate(format: predicate), evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    /// Downloads the demo finder's Internet Archive result `id` ("ia-Test-1") and returns its Downloads row. With
    /// `searched`, the results for "test" are already listed in Get Music.
    @MainActor
    private func download(_ app: XCUIApplication, _ id: String, searched: Bool = false) -> XCUIElement {
        app.tabBars.buttons["Get Music"].tap()
        if !searched {
            let field = app.searchFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 3))
            field.tap()
            field.typeText("test\n")
        }
        let download = app.buttons["download-\(id)"]
        XCTAssertTrue(download.waitForExistence(timeout: 4))
        download.tap()
        app.tabBars.buttons["Downloads"].tap()
        let row = app.descendants(matching: .any)["downloadRow-\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        return row
    }

    /// Opens the Downloads toolbar menu and picks the item `id`.
    @MainActor
    private func openMenu(_ app: XCUIApplication, choosing id: String) {
        let menu = app.buttons["downloadsMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        menu.tap()
        let item = app.buttons[id]
        XCTAssertTrue(item.waitForExistence(timeout: 3), "no \(id) in the menu")
        item.tap()
    }

    /// Taps the tab `name` until `element` shows: a tap made while the app is still coming back to the foreground
    /// can be lost.
    @MainActor
    private func open(_ app: XCUIApplication, tab name: String, showing element: XCUIElement) {
        for _ in 0..<3 where !element.exists {
            app.tabBars.buttons[name].tap()
            _ = element.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(element.exists, "the \(name) tab did not open")
    }

    /// Opens the shelf and searches it for `album`: whether its result shows.
    @MainActor
    private func isOnShelf(_ app: XCUIApplication, _ album: String) -> Bool {
        let shelf = app.buttons["shelfButton"]
        open(app, tab: "Player", showing: shelf)
        shelf.tap()
        let field = app.textFields["shelfSearch"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText(album.lowercased())
        return app.buttons["result-album-\(album)"].waitForExistence(timeout: 4)
    }

    /// The last "N%" in a row's label: how far the download had got.
    private static func percent(_ label: String) -> Int? {
        guard let range = label.range(of: #"(\d+)%"#, options: [.regularExpression, .backwards]) else { return nil }
        return Int(label[range].dropLast())
    }
}
