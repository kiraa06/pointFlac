import XCTest

/// Plan 11: playlists as custom pressings. Favourites and named playlists in the shelf's strip, the heart on the
/// player, the Add to Playlist, New Playlist and playlist sheets, and a playlist played on the deck.
///
/// Every launch opens a library of its own (`-PFFreshLibrary`) with the demo albums in it (`-PFPreloadFixtures`), so
/// Favourites starts empty and no playlist an earlier run made is there. The Crate is pinned through the argument
/// domain (`-shelfMode crate`), which writes nothing.
final class PlaylistUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The heart puts the song on the deck into Favourites; Favourites' disc then counts it, and tapping the disc flies
    /// the pressing to the deck, which plays that song.
    @MainActor
    func testHeartAddsToFavouritesAndItPlays() {
        let app = launch(demoPlay: true)
        let heart = app.buttons["favouriteButton"]
        XCTAssertTrue(heart.waitForExistence(timeout: 8))
        // Night Drive is on the deck once the heart names its first song.
        wait(for: heart, "value == 'Ignition'", timeout: 8)
        XCTAssertEqual(heart.label, "Add to Favourites")
        heart.tap()
        wait(for: heart, "label == 'Remove from Favourites'")
        XCTAssertTrue(heart.isSelected)

        openShelf(app)
        let favourites = app.buttons["playlistDisc-favourites"]
        XCTAssertTrue(favourites.waitForExistence(timeout: 5))
        wait(for: favourites, "label == 'Favourites, playlist, 1 song'")
        favourites.tap()

        let record = app.descendants(matching: .any)["deckRecord"]
        wait(for: record, "label == 'Record, Favourites'", timeout: 10)
        let screen = app.descendants(matching: .any)["deckDisplay"]
        XCTAssertTrue(screen.exists)
        wait(for: app.staticTexts["nowPlayingTitle"], "label == 'Ignition'", timeout: 8)
        // Still hearted: it is the song playing now, from Favourites.
        XCTAssertEqual(app.buttons["favouriteButton"].label, "Remove from Favourites")
    }

    /// New makes a playlist with the name typed; an album's Add to Playlist… puts all its songs in it.
    @MainActor
    func testCreatePlaylistAndAddAnAlbum() {
        let app = launch()
        openShelf(app)
        let new = app.buttons["newPlaylistButton"]
        XCTAssertTrue(new.waitForExistence(timeout: 5))
        new.tap()
        let field = app.textFields["newPlaylistName"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertEqual(field.value as? String, "New Playlist")
        replaceText(in: field, with: "Late Night")
        app.buttons["createPlaylist"].tap()

        let disc = playlistDisc(named: "Late Night", in: app)
        XCTAssertTrue(disc.waitForExistence(timeout: 5))
        wait(for: disc, "label == 'Late Night, playlist, 0 songs'")

        holdAlbumResult("paper moons", title: "Paper Moons", in: app)
        let add = app.buttons["Add to Playlist…"]
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        add.tap()
        XCTAssertTrue(app.descendants(matching: .any)["addToPlaylistSheet"].waitForExistence(timeout: 3))
        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'addToPlaylist-' AND label BEGINSWITH 'Late Night, '")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        let sheet = app.descendants(matching: .any)["addToPlaylistSheet"]
        wait(for: sheet, "exists == false")

        clearSearch(app)
        wait(for: playlistDisc(named: "Late Night", in: app), "label == 'Late Night, playlist, 4 songs'")
    }

    /// Removing a song from a playlist takes it out of the playlist only: its album keeps all its songs.
    @MainActor
    func testRemoveSongFromPlaylistKeepsItInLibrary() {
        let app = launch()
        openShelf(app)
        holdAlbumResult("paper moons", title: "Paper Moons", in: app)
        let add = app.buttons["Add to Playlist…"]
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        add.tap()
        let favouritesRow = app.buttons["addToPlaylist-favourites"]
        XCTAssertTrue(favouritesRow.waitForExistence(timeout: 3))
        favouritesRow.tap()
        wait(for: app.descendants(matching: .any)["addToPlaylistSheet"], "exists == false")
        clearSearch(app)

        let favourites = app.buttons["playlistDisc-favourites"]
        wait(for: favourites, "label == 'Favourites, playlist, 4 songs'")
        favourites.press(forDuration: 1.2)
        let open = app.buttons["Open Playlist"]
        XCTAssertTrue(open.waitForExistence(timeout: 3))
        open.tap()
        XCTAssertTrue(app.descendants(matching: .any)["playlistSheet"].waitForExistence(timeout: 3))
        let first = app.buttons["playlistSong-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        let removed = first.label
        XCTAssertTrue(app.buttons["playlistSong-3"].exists)
        first.swipeLeft()
        let remove = app.buttons["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        remove.tap()
        wait(for: app.buttons["playlistSong-3"], "exists == false")
        XCTAssertNotEqual(app.buttons["playlistSong-0"].label, removed)
        app.buttons["closePlaylist"].tap()

        wait(for: favourites, "label == 'Favourites, playlist, 3 songs'")
        let result = searchAlbum("paper moons", title: "Paper Moons", in: app)
        XCTAssertTrue(result.label.contains("4 tracks"), "the album reads \"\(result.label)\"")
    }

    /// Favourites offers no Delete Playlist… anywhere: not in its disc's menu, not in its sheet, where its name is not
    /// editable either. A playlist the user made offers both.
    @MainActor
    func testFavouritesCannotBeDeleted() {
        let app = launch()
        openShelf(app)
        let favourites = app.buttons["playlistDisc-favourites"]
        XCTAssertTrue(favourites.waitForExistence(timeout: 5))
        favourites.press(forDuration: 1.2)
        let open = app.buttons["Open Playlist"]
        XCTAssertTrue(open.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Delete Playlist…"].exists)
        open.tap()
        XCTAssertTrue(app.descendants(matching: .any)["playlistSheet"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["playlistName"].exists)
        XCTAssertFalse(app.textFields["playlistName"].exists)
        XCTAssertFalse(app.buttons["deletePlaylist"].exists)
        app.buttons["closePlaylist"].tap()
        wait(for: app.descendants(matching: .any)["playlistSheet"], "exists == false")

        // The control: a playlist of the user's own can be deleted, from its menu.
        app.buttons["newPlaylistButton"].tap()
        let create = app.buttons["createPlaylist"]
        XCTAssertTrue(create.waitForExistence(timeout: 3))
        create.tap()
        let made = playlistDisc(named: "New Playlist", in: app)
        XCTAssertTrue(made.waitForExistence(timeout: 5))
        made.press(forDuration: 1.2)
        let delete = app.buttons["Delete Playlist…"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        let confirm = app.buttons["Delete Playlist"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        wait(for: made, "exists == false")
        XCTAssertTrue(favourites.exists)
    }

    /// Deleting a song from the library takes it out of every playlist.
    @MainActor
    func testDeletingASongLeavesPlaylists() {
        let app = launch()
        openShelf(app)
        holdSongResult("ignition", title: "Ignition", in: app)
        // The menu's item, not the player's heart under the shelf, which reads the same.
        let heart = app.buttons.matching(
            NSPredicate(format: "label == 'Add to Favourites' AND identifier != 'favouriteButton'")
        ).firstMatch
        XCTAssertTrue(heart.waitForExistence(timeout: 3))
        heart.tap()
        clearSearch(app)
        let favourites = app.buttons["playlistDisc-favourites"]
        wait(for: favourites, "label == 'Favourites, playlist, 1 song'")

        holdSongResult("ignition", title: "Ignition", in: app)
        let delete = app.buttons["Delete Song…"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        let confirm = app.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        wait(for: app.buttons["result-track-Ignition"], "exists == false")

        clearSearch(app)
        wait(for: favourites, "label == 'Favourites, playlist, 0 songs'")
    }

    /// A fresh library's Favourites is empty: its disc says so, and a tap opens its sheet, with the empty line, rather
    /// than flying an empty record to the deck.
    @MainActor
    func testFavouritesShowsItsEmptyStateOnAFreshLibrary() {
        let app = launch()
        openShelf(app)
        let favourites = app.buttons["playlistDisc-favourites"]
        XCTAssertTrue(favourites.waitForExistence(timeout: 5))
        XCTAssertEqual(favourites.label, "Favourites, playlist, 0 songs")
        favourites.tap()
        XCTAssertTrue(app.descendants(matching: .any)["playlistSheet"].waitForExistence(timeout: 3))
        let empty = app.staticTexts["playlistEmpty"]
        XCTAssertTrue(empty.waitForExistence(timeout: 3))
        XCTAssertEqual(
            empty.label, "No songs yet. Tap ♥ on the player, or long-press any album or song to add it.")
        XCTAssertFalse(app.buttons["playPlaylist"].isEnabled)
        XCTAssertFalse(app.descendants(matching: .any)["deckRecord"].exists)
    }

    /// A playlist waiting in Up Next that has been emptied since is passed over: Up Next carries on with the record
    /// after it.
    @MainActor
    func testEmptiedPlaylistInUpNextIsSkipped() {
        let app = launch(demoPlay: true)
        let heart = app.buttons["favouriteButton"]
        XCTAssertTrue(heart.waitForExistence(timeout: 8))
        wait(for: heart, "value == 'Ignition'", timeout: 8)
        heart.tap()
        wait(for: heart, "label == 'Remove from Favourites'")

        // Up Next: Favourites (Ignition), then Paper Moons.
        openShelf(app)
        let favourites = app.buttons["playlistDisc-favourites"]
        wait(for: favourites, "label == 'Favourites, playlist, 1 song'")
        favourites.press(forDuration: 1.2)
        let queue = app.buttons["Add to Up Next"]
        XCTAssertTrue(queue.waitForExistence(timeout: 3))
        queue.tap()
        holdAlbumResult("paper moons", title: "Paper Moons", in: app)
        XCTAssertTrue(queue.waitForExistence(timeout: 3))
        queue.tap()
        clearSearch(app)

        // Favourites is emptied while it waits.
        holdSongResult("ignition", title: "Ignition", in: app)
        let unheart = app.buttons.matching(
            NSPredicate(format: "label == 'Remove from Favourites' AND identifier != 'favouriteButton'")
        ).firstMatch
        XCTAssertTrue(unheart.waitForExistence(timeout: 3))
        unheart.tap()
        clearSearch(app)
        wait(for: favourites, "label == 'Favourites, playlist, 0 songs'")
        closeShelf(app)

        // From the record's last song, Next goes past the empty Favourites to Paper Moons.
        let tracklist = app.buttons["tracklistButton"]
        XCTAssertTrue(tracklist.waitForExistence(timeout: 3))
        tracklist.tap()
        let last = app.buttons["tracklistTrack-4"]
        XCTAssertTrue(last.waitForExistence(timeout: 3))
        last.tap()
        wait(for: app.staticTexts["nowPlayingTitle"], "label == 'Last Exit'")
        app.buttons["nextButton"].tap()
        let record = app.descendants(matching: .any)["deckRecord"]
        wait(for: record, "label == 'Record, Paper Moons'", timeout: 8)
        wait(for: app.staticTexts["nowPlayingTitle"], "label == 'Fold'", timeout: 8)
    }

    /// A name typed in the playlist sheet is kept when the sheet is closed with Done while the field still has the
    /// keyboard.
    @MainActor
    func testRenameTypedInThePlaylistSheetIsKeptOnDone() {
        let app = launch()
        openShelf(app)
        let new = app.buttons["newPlaylistButton"]
        XCTAssertTrue(new.waitForExistence(timeout: 5))
        new.tap()
        let create = app.buttons["createPlaylist"]
        XCTAssertTrue(create.waitForExistence(timeout: 3))
        create.tap()
        let made = playlistDisc(named: "New Playlist", in: app)
        XCTAssertTrue(made.waitForExistence(timeout: 5))
        wait(for: made, "isHittable == true")
        // Empty, so a tap opens its sheet.
        made.tap()
        let field = app.textFields["playlistName"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        replaceText(in: field, with: "Road Trip")
        app.buttons["closePlaylist"].tap()
        wait(for: app.descendants(matching: .any)["playlistSheet"], "exists == false")
        let renamed = playlistDisc(named: "Road Trip", in: app)
        XCTAssertTrue(renamed.waitForExistence(timeout: 3))
        XCTAssertEqual(renamed.label, "Road Trip, playlist, 0 songs")
    }

    /// The record on the deck plays the songs it was cued with; an edit applies the next time the playlist is cued. A
    /// song taken out of the playlist on the deck, from the deck's own tracklist, stays listed there and Next still
    /// plays it; the playlist cued again from the strip has one song fewer.
    @MainActor
    func testEditingThePlaylistOnTheDeckChangesNothingThatPlays() {
        // Late Night Drives: Neon Mile, Apogee, Fold.
        let app = launch(["-PFDemoPlaylists", "-PFPlayPlaylist", "Late Night Drives"])
        let title = app.staticTexts["nowPlayingTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        wait(for: title, "label == 'Neon Mile'", timeout: 10)

        // Apogee leaves the playlist from the deck's tracklist.
        openTracklist(app)
        let apogee = app.buttons["tracklistTrack-1"]
        XCTAssertTrue(apogee.waitForExistence(timeout: 3))
        XCTAssertTrue(apogee.label.contains("Apogee"), "the row reads \"\(apogee.label)\"")
        apogee.press(forDuration: 1.2)
        let remove = app.buttons["Remove from This Playlist"]
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        remove.tap()
        wait(for: remove, "exists == false")
        // Neon Mile again from its start, which closes the sheet.
        app.buttons["tracklistTrack-0"].tap()
        wait(for: app.descendants(matching: .any)["tracklistSheet"], "exists == false")

        // The playlist has lost it...
        openShelf(app)
        wait(for: playlistDisc(named: "Late Night Drives", in: app), "label == 'Late Night Drives, playlist, 2 songs'")
        closeShelf(app)

        // ...but the record on the deck still lists it, and Next plays it.
        openTracklist(app)
        wait(for: app.buttons["tracklistTrack-1"], "label CONTAINS 'Apogee'")
        wait(for: app.buttons["tracklistTrack-2"], "label CONTAINS 'Fold'")
        app.buttons["tracklistTrack-0"].tap()
        wait(for: app.descendants(matching: .any)["tracklistSheet"], "exists == false")
        wait(for: title, "label == 'Neon Mile'")
        app.buttons["nextButton"].tap()
        wait(for: title, "label == 'Apogee'", timeout: 8)
        wait(for: app.buttons["playButton"], "label == 'Pause'", timeout: 8)

        // Cued again from the strip, the playlist plays as it is now: two songs, Apogee gone.
        openShelf(app)
        let disc = playlistDisc(named: "Late Night Drives", in: app)
        XCTAssertTrue(disc.waitForExistence(timeout: 3))
        disc.tap()
        wait(for: app.textFields["shelfSearch"], "exists == false", timeout: 8)
        wait(for: title, "label == 'Neon Mile'", timeout: 8)
        openTracklist(app)
        wait(for: app.buttons["tracklistTrack-1"], "label CONTAINS 'Fold'")
        XCTAssertFalse(app.buttons["tracklistTrack-2"].exists)
    }

    /// Over the galaxy a disc's hold asks in a dialog, not a context menu (the delete half of
    /// `testFavouritesCannotBeDeleted`). Delete Playlist… there leads on to the delete confirmation, which deletes the
    /// playlist; Favourites' dialog offers no Delete.
    @MainActor
    func testGalaxyStripDeletesAPlaylistButNeverFavourites() {
        let app = launch(shelfMode: "galaxy")
        openShelf(app)
        XCTAssertTrue(app.descendants(matching: .any)["shelfGalaxy"].waitForExistence(timeout: 5))
        let new = app.buttons["newPlaylistButton"]
        XCTAssertTrue(new.waitForExistence(timeout: 5))
        new.tap()
        let create = app.buttons["createPlaylist"]
        XCTAssertTrue(create.waitForExistence(timeout: 3))
        create.tap()
        let made = playlistDisc(named: "New Playlist", in: app)
        XCTAssertTrue(made.waitForExistence(timeout: 5))
        wait(for: made, "isHittable == true")

        made.press(forDuration: 1.2)
        // A dialog's button can be listed twice (the popover's button inside its own): the first will do.
        let delete = app.buttons["Delete Playlist…"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        let confirm = app.buttons["Delete Playlist"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "no delete confirmation followed the hold's dialog")
        confirm.tap()
        wait(for: made, "exists == false")

        let favourites = app.buttons["playlistDisc-favourites"]
        XCTAssertTrue(favourites.exists)
        favourites.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Open Playlist"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Delete Playlist…"].exists)
    }

    // MARK: Helpers

    /// Opens the tracklist sheet from the song line under the title.
    @MainActor
    private func openTracklist(_ app: XCUIApplication) {
        let button = app.buttons["tracklistButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        button.tap()
        XCTAssertTrue(app.descendants(matching: .any)["tracklistSheet"].waitForExistence(timeout: 3))
    }

    /// Drags the shelf's grabber down, which closes it.
    @MainActor
    private func closeShelf(_ app: XCUIApplication) {
        let grabber = app.descendants(matching: .any)["Close the shelf"].firstMatch
        XCTAssertTrue(grabber.waitForExistence(timeout: 3))
        let start = grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 300)))
        wait(for: app.textFields["shelfSearch"], "exists == false")
    }

    /// `shelfMode` pins the shelf's mode for the launch; `extra` comes last.
    @MainActor
    private func launch(demoPlay: Bool = false, shelfMode: String = "crate", _ extra: [String] = []) -> XCUIApplication
    {
        let app = XCUIApplication.pointFlac(
            ["-PFPreloadFixtures", "-PFFreshLibrary", "-PFStage", "deck", "-shelfMode", shelfMode]
                + (demoPlay ? ["-PFDemoPlay"] : []) + extra)
        app.launch()
        return app
    }

    @MainActor
    private func openShelf(_ app: XCUIApplication) {
        let button = app.buttons["shelfButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        XCTAssertTrue(app.textFields["shelfSearch"].waitForExistence(timeout: 3))
    }

    /// Waits up to `timeout` seconds for `element` to match `format`.
    @MainActor
    private func wait(for element: XCUIElement, _ format: String, timeout: TimeInterval = 5) {
        expectation(for: NSPredicate(format: format), evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    @MainActor
    private func playlistDisc(named name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'playlistDisc-' AND label BEGINSWITH %@", "\(name), playlist")
        ).firstMatch
    }

    /// Types `query` into the shelf's search and returns the album result `title`.
    @MainActor
    private func searchAlbum(_ query: String, title: String, in app: XCUIApplication) -> XCUIElement {
        search(query, in: app)
        let result = app.buttons["result-album-\(title)"]
        XCTAssertTrue(result.waitForExistence(timeout: 3))
        return result
    }

    /// Searches the shelf for `query`, and puts the keyboard away (Search), so every result can be reached.
    @MainActor
    private func search(_ query: String, in app: XCUIApplication) {
        let field = app.textFields["shelfSearch"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText(query + "\n")
    }

    @MainActor
    private func holdAlbumResult(_ query: String, title: String, in app: XCUIApplication) {
        searchAlbum(query, title: title, in: app).press(forDuration: 1.2)
    }

    @MainActor
    private func holdSongResult(_ query: String, title: String, in app: XCUIApplication) {
        search(query, in: app)
        let result = app.buttons["result-track-\(title)"]
        XCTAssertTrue(result.waitForExistence(timeout: 3))
        result.press(forDuration: 1.2)
    }

    /// Clears the shelf's search, which brings the strip back, and puts the keyboard away.
    @MainActor
    private func clearSearch(_ app: XCUIApplication) {
        let clear = app.buttons["Clear search"]
        if clear.waitForExistence(timeout: 2) { clear.tap() }
        XCTAssertTrue(app.buttons["newPlaylistButton"].waitForExistence(timeout: 3))
    }

    /// Replaces a text field's text: the caret goes to the end (the field selects its whole text when focused, too),
    /// then deletes clear it, and `text` is typed.
    @MainActor
    private func replaceText(in field: XCUIElement, with text: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2) + text)
    }
}
