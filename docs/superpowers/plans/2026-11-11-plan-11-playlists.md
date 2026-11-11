# Plan 11: Playlists as custom pressings

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Favourites plus named playlists, each drawn and played as its own custom-pressed vinyl record.

**Architecture:**
- The package stores playlists in a v6 migration, with soft track references and a pruning step in delete.
- The app presents a playlist to the player as a synthetic `AlbumCard` (`playlist:<id>`) carrying a `pressing` look, so the deck, the sides, Up Next and the hand-off work unchanged.
- The pressing art is a new set of views under `App/Deck/`.
- The UI adds a Playlists strip on the shelf, a heart on the player, tracklist and shelf menus, and three sheets.

**Tech stack:** Swift 6 strict concurrency, SwiftUI on iOS 26, Swift Testing, XCTest UI tests, XcodeGen (`scripts/bootstrap.sh`).

**Spec:** `docs/superpowers/specs/2026-11-11-playlist-pressings-design.md`. It is binding for words, colours and geometry. The visual reference is the mockup at `/Users/kiranjose/Documents/Echocore/.superpowers/brainstorm/playlists-1/content/pressings.html`, once it exists.

**Code map:** `.superpowers/sdd/2026-11-11-playlists/codemap.md`. Read it before exploring.

## Global Constraints
- **Lint and concurrency:** Swift 6 strict concurrency. `swift format lint --strict --recursive App AppUITests Packages` must stay clean.
- **Files are sacred:** deleting a playlist, or removing a song from one, never touches files or the library catalog.
- **Monochrome:** greys the vinyl and the interface, but album covers stay in colour.
- **Accessibility:** every control has a label, decorative art is hidden from VoiceOver, Reduce Motion is respected, and Dynamic Type must not break layouts.
- **Keep what exists:** every existing identifier and behaviour of the deck, the shelf, the tracklist, the hand-off and Up Next stays as it is.
- **Audio:** never touch the audio render thread.
- **Commits:**
  - Conventional Commits, as `Kiran P Jose <kiran.p.jose02@gmail.com>`.
  - **NO Co-Authored-By or any AI-attribution line.**
  - Never push. No subagents.
- **Machines:** only the simulator and the `-derivedDataPath` named in your task.

## Review Focus
1. Deleting a song (shelf, Downloads, or the move to Recently Deleted) removes it from every playlist. A song whose file is only missing for now comes back into its playlists when the file returns.
2. Playing a playlist whose songs come from albums with different formats and sample rates keeps the gapless queue and the signal strip honest per song.
3. A playlist with songs that are unsupported (multichannel) or cloud-pending skips them without breaking the sides or the tracklist indices.
4. Editing a playlist while it is on the deck does not corrupt `playback.tracks` or Up Next. Edits apply the next time it is cued.
5. Favourites can't be deleted or renamed by any path, including an empty or duplicate name.

---

### Task A: Playlist storage (package)

**Owns:**
- `Packages/PointFlacKit/Sources/PFCore/Playlist.swift` (new);
- `PFLibrary/LibraryStore.swift` and `PFLibrary/Library.swift` (the playlist parts and the prune step in `remove`);
- new tests in `Tests/PFLibraryTests/PlaylistTests.swift`.

**Interfaces it produces:**
- `public struct Playlist: Sendable, Hashable, Identifiable { id: String; name: String; kind: Kind; colourID: String; createdAt: Date; trackIDs: [String] }`, where `Kind` is `favourites` or `custom`.
- `public static let favouritesID = "favourites"`.
- `Library` methods. Each returns the updated `[Playlist]` (all playlists, Favourites first, then by `createdAt`) or throws `PlaylistError`:
  - `playlists() -> [Playlist]`
  - `createPlaylist(name: String, colourID: String) throws -> Playlist`
  - `renamePlaylist(id:name:) throws`
  - `setPlaylistColour(id:colourID:) throws`
  - `deletePlaylist(id:) throws`
  - `addTracks(_ ids: [String], to playlistID: String) throws -> Int`, which returns the number added
  - `removeTracks(_ ids: [String], from playlistID: String) throws`
  - `reorderPlaylist(id:trackIDs:) throws`
- `PlaylistError`: `notFound`, `favouritesIsFixed`, `invalidName`.

**Behaviour:**
- **Migration v6:** exactly the schema in spec §5, and it seeds Favourites (`id = favourites`, `name = "Favourites"`, `colour = "ruby"`).
- **Names:** trimmed, 1–60 characters, otherwise `invalidName`. Duplicate names are allowed.
- **Favourites:** renaming or deleting it throws `favouritesIsFixed`.
- **Adding:** a song is appended once; repeats and songs already present are skipped. Adding to a playlist that doesn't exist throws `notFound`.
- **Reordering:** the given IDs, in order, must be the same set as the playlist's current set, otherwise it throws `notFound`. It rewrites the positions.
- **`playlists()` returns all stored track IDs**, unfiltered. The app filters to the catalog.
- **`remove(trackIDs:trashing:)`** also deletes those track IDs from `playlist_tracks`, in the same write transaction as the track rows. That covers successful trashes and plain removals alike; a deliberate delete always leaves playlists.
- **A rescan that drops a gone file does NOT prune playlists**, so a song whose file is only missing comes back.
- **No catalog republish:** playlist calls use `run(.never)`.
- **A database at v5 migrates** with no data loss.

- [ ] **Step 1:** Write the failing tests, covering each behaviour above. Include a test that a song removed through `remove(trackIDs:)` leaves every playlist, and one that a file gone at rescan stays in its playlist. Run `swift test --filter PlaylistTests` and see it fail.
- [ ] **Step 2:** Implement until it passes. Then run all of PFLibrary and PFCore, and lint.
- [ ] **Step 3:** Commit: `feat(library): playlists, with Favourites, stored in the library`.

### Task B: The pressing art (app views)

This runs in parallel with Task A and depends only on PFDesign.

**Owns:**
- `Packages/PointFlacKit/Sources/PFDesign/Pressing.swift` (new), with tests in `PFDesignTests`;
- new `App/Deck/Pressing*.swift` files;
- `App/Deck/DeckRecord.swift`, for the pressing branch of `RecordFace` and `RecordView`;
- a DEBUG-only gallery screen, `App/Debug/PressingGalleryView.swift`, reached with the launch argument `-PFPressingGallery`.

It must NOT edit `Contracts.swift`, the shelf, the player screens or the library.

**Interfaces it produces:**
- In PFDesign:
  - `public enum PressingColour: String, CaseIterable, Sendable { ruby, amber, citrine, jade, ocean, violet, smoke, onyx }`, with `name` ("Ruby"…), `hex: UInt32` from spec §3, `static let favouritesDefault = .ruby`, and `static func next(after used: [PressingColour]) -> PressingColour`, following the spec's rotation and skipping colours in use.
  - `public enum PressingMonogram { static func letters(_ name: String) -> String }`, which takes the initials of the first two words, upper-cased. It never returns a heart: the Favourites badge draws its heart itself.
- In the app:
  - `struct PressingLook: Hashable, Sendable { title: String; colour: PressingColour; coverAlbumIDs: [String]; songCount: Int; isFavourites: Bool; id: String }`. `coverAlbumIDs` holds up to 6 distinct album IDs, in playlist order.
  - `PressingLabel(look:side:diameter:)`, per spec §3.
  - `PressingDisc(look:size:)`, the 56–64 pt shelf disc, with no rim text.
  - `PressingCoverMosaic(look:)`, a square 2×2 mosaic used where a square cover is needed.
  - `RecordFace(pressing: PressingLook, side:bands:)`. When `RecordView` gets a pressing face, it ignores `RecordStyle`:
    - it draws coloured vinyl tinted with the pressing colour (grey in Monochrome);
    - it uses `PressingLabel`;
    - its rim text is `FAVOURITES · 24 SONGS · SIDE A · 33⅓ RPM`;
    - its matrix is `PFL-FAV-A1` or `PFL-MIX-<first 4 of id>-A1`.
- **Every view takes album IDs and uses the existing `ArtworkView`** for the covers, so real artwork loads through `ArtworkLoader`.
- **Rasterise the static parts** (`drawingGroup` or a cached image), so the deck holds 120 Hz.

- [ ] **Step 1:** PFDesign tests: eight colours with the spec's hex values in order; `next(after:)` rotation and skipping; monogram cases ("Late Night Drives" → "LN", "gym" → "G", "  road  trip 2026" → "RT", an emoji-only name → its first character). See them fail, then implement.
- [ ] **Step 2:** Build the views. Match the mockup's look; where the mockup and the spec disagree, the spec wins on geometry and words, and the mockup wins on finish.
- [ ] **Step 3:** The gallery (`-PFPressingGallery -PFPreloadFixtures`) shows the eight example playlists from the mockup, built from the fixture albums. Each appears as a deck-size record, a shelf disc and a cover mosaic, plus one Favourites record on the real Glasshouse deck if that's practical.
  - Take screenshots to `scratchpad/pressing-*.png`: light, dark, Monochrome, and the largest accessibility text size.
  - Simulator `pointFlac-sui`, derived data `scratchpad/dd-pressB`.
  - Look at each screenshot and fix whatever looks fake, then lint and commit: `feat(deck): custom pressing art for playlists`.

### Task C: Wire it in (after A and B are merged)

**Owns:**
- `App/Model/Contracts.swift`;
- `App/Integration/RealLibrary.swift`;
- `App/Model/PlaybackController.swift`, only if it is needed;
- `App/Player/CoverStage.swift`, `HandoffDirector.swift`, `SharedControls.swift`, `TracklistSheet.swift` and `DeckTracklist.swift`;
- `App/Deck/DeckStage.swift` and `DeckDisplay.swift`, where the record and the idle line are built;
- `App/Shelf/ShelfPanel.swift` and `GalaxyView.swift`, for the menu items;
- new `App/Playlists/*.swift`;
- new `AppUITests/PlaylistUITests.swift`.

**Requirements** (spec §4 is binding):
- **Model:**
  - `AlbumCard` gains `pressing: PressingLook?` (nil for albums), and `TrackRow` gains `albumID: String?`.
  - `LibraryBrowsing` gains:
    - `playlists: [PlaylistCard]`, each with id, name, isFavourites, colour, songIDs filtered to playable catalog songs, look, and an `albumCard`;
    - create / rename / recolour / delete;
    - `add(_ trackIDs:to:)`, `remove(_ trackIDs:from:)`, `reorder`;
    - `isFavourite(_ trackID:)` and `toggleFavourite(_ trackID:)`.
  - `RealLibrary` keeps the playlists in sync after every call and when the catalog changes.
  - `tracks(of: "playlist:<id>")` returns the playlist's playable songs in order, with side codes. `queueItems` is unchanged.
- **Playback:** a playlist card plays through the existing hand-off and `load` paths:
  - the deck draws the pressing;
  - the idle display reads `FAVOURITES·24 SONGS`;
  - the cover view shows the current song's own album cover, with the pressing peeking out;
  - the hand-off flies the disc, with no sleeve sinking;
  - Up Next accepts playlists.
- **UI:**
  - the Playlists strip;
  - the heart (`favouriteButton`);
  - the tracklist row menus (sheet and deck display);
  - "Add to Playlist…" on albums, and the song-result items;
  - the Add to Playlist, New Playlist and playlist sheets.
  All with the spec's words, identifiers, haptics and motion.
- **Removal:** the existing delete flows (shelf and Downloads) refresh the playlists afterwards.

- [ ] **Step 1:** Write `PlaylistUITests` first (simulator `pointFlac-s7`, derived data `scratchpad/dd-plC`, launch `-PFPreloadFixtures -PFStage deck`):
  - `testHeartAddsToFavouritesAndItPlays`: play Night Drive, tap `favouriteButton`, open the shelf, see `playlistDisc-favourites` with "1 song", tap it, and the deck plays that song with the pressing (`deckRecord` exists, and `nowPlayingTitle` matches).
  - `testCreatePlaylistAndAddAnAlbum`: `newPlaylistButton`, type "Late Night", Create, long-press the Paper Moons sleeve, Add to Playlist…, tap the new playlist, and its disc shows "4 songs".
  - `testRemoveSongFromPlaylistKeepsItInLibrary`: open the playlist sheet, swipe to remove a song, and the album still shows 4 tracks.
  - `testFavouritesCannotBeDeleted`: the long-press menu on Favourites has no Delete Playlist.
  - `testDeletingASongLeavesPlaylists`: add a song to Favourites, delete the song via Delete Song…, and Favourites shows "0 songs" or its empty state.
  See them fail.
- [ ] **Step 2:** Implement until the new tests pass. Then run the existing PlayerUITests, ShelfUITests (or whatever covers the shelf), DownloadControlsUITests and the package tests.
- [ ] **Step 3:** Take screenshots to `scratchpad/pl-*.png`: the shelf strip (light, dark, Monochrome), the deck playing Favourites, the cover view, the three sheets, and accessibility text sizes. Look at each and fix what's cramped or fake, then lint and commit in logical commits.

### Task D: Integrate and check
- [ ] Merge the Task A and B branches into `feat/record-crate` before Task C starts.
- [ ] After Task C, run the full `scripts/test.sh` on `pointFlac-s1415`.
- [ ] A final whole-branch review on opus, focused on Review Focus 1–5.
- [ ] Do not push; Kiran decides.
