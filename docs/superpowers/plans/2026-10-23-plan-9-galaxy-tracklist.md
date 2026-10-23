# Shelf Galaxy and Tracklist Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a physics-driven Galaxy mode to the Shelf, sized and ordered by new listen history and other sorts. Add a Tracklist: a back-cover sheet, plus the Deck's dot-matrix display unfolding, to jump to any song on the record.

**Architecture:**
- **Listen history** lives in the library database, in a new `listens` table keyed by track content ID. The app counts listens from the player's position with a pure rule.
- **Galaxy engine** is pure, host-testable Swift in `PFDesign`: a placement algorithm, a collision step and the drift maths. The app draws it in one `Canvas`, using `Sleeve` symbols, inside a `TimelineView`.
- **Tracklist** is app UI over `PlaybackController`'s existing album, tracks and `SideLayout`.

**Tech Stack:**
- Swift 6 with strict concurrency, SwiftUI (iOS 26) and Swift Testing.
- XCTest for UI tests.
- SQLite through `PFLibrary`'s `SQLiteDatabase`.

**Spec:** `docs/superpowers/specs/2026-10-23-galaxy-tracklist-design.md`

## Global Constraints

- **Language mode.** Swift 6 language mode with strict concurrency. No `@unchecked Sendable` without a comment that justifies it.
- **Lint.** `swift format lint --strict --recursive App AppUITests Packages` stays clean.
- **Colour.** Colours come from `Theme` tokens and respect `\.isMonochrome`. Artwork stays in colour.
- **Accessibility.** Every control has an accessibility label (and a value where it has one). Dynamic Type must not break layouts. Reduce Motion is respected.
- **Audio render thread.** Never touch the audio render thread code (`PFAudio/RenderSource.swift`, `PFDSP` chains).
- **Commits.**
  - Conventional Commits, as the repo-local identity `Kiran P Jose <kiran.p.jose02@gmail.com>`. Verify with `git log -1 --format='%an <%ae>'`.
  - End every message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
  - No Jira prefix.
- **Agent discipline.**
  - **Never push.** No subagents, no lingering background loops.
  - Each UI-testing agent uses its own simulator, named in its brief.
  - At most two heavy builds or test runs on the machine at once.
- **Tests.** Swift Testing (`@Test`, `#expect`) for package and host tests; XCTest for UI tests in `AppUITests`.

## Review Focus

1. **Seeking, scrubbing or pausing must never count as a listen.**
   - A listener who jumps to near the end, or scrubs, gets no listen.
   - A listen counts once per play-through, not again every poll after the threshold.
   - Pinned in Task 1 (`ListenRuleTests`).
2. **Ties and missing years.**
   - Albums with no year, and albums tied on every key, keep a stable, deterministic order. No reshuffle on every layout.
   - With zero listens anywhere, Most played orders as Last added.
   - Pinned in Task 1 (`AlbumOrderTests`).
3. **Placement on awkward inputs.** It must terminate and keep every pair apart:
   - one album;
   - two albums;
   - 1,000 albums;
   - every album the same rank.
   - Pinned in Task 2 (`GalaxyLayoutTests`).
4. **A dragged sleeve dropped onto a crowded edge.**
   - Once settled, nothing overlaps.
   - Homes become the settled positions.
   - Pinned in Task 2 (`GalaxyPhysicsTests`).
5. **The track jump on a different side.**
   - Picking B1 while on side A must land on side B and play B1. The deck flips, it doesn't merely seek.
   - The sheet must survive a track change while open.
   - Pinned in Task 3 (`testTracklistJumpsToLastTrack`).

---

### Task 1: Listen history and album sort keys

**Files:**
- Modify: `Packages/PointFlacKit/Sources/PFLibrary/LibraryStore.swift` (migration v5, listen queries).
- Modify: `Packages/PointFlacKit/Sources/PFLibrary/Library.swift` (public API).
- Modify: `Packages/PointFlacKit/Sources/PFCore/LibraryModels.swift` (`LibraryTrack.addedAt`, `LibraryAlbum.addedAt`).
- Create: `Packages/PointFlacKit/Sources/PFCore/ListenRule.swift`.
- Create: `Packages/PointFlacKit/Sources/PFCore/AlbumOrder.swift`.
- Modify: `App/Model/Contracts.swift` (`AlbumCard` fields, `LibraryBrowsing` additions).
- Modify: `App/Integration/RealLibrary.swift`.
- Modify: `App/Model/PlaybackController.swift` (listen tracking).
- Tests:
  - `Packages/PointFlacKit/Tests/PFCoreTests/ListenRuleTests.swift`;
  - `Packages/PointFlacKit/Tests/PFCoreTests/AlbumOrderTests.swift`;
  - `Packages/PointFlacKit/Tests/PFLibraryTests/ListenStoreTests.swift`.

**Interfaces:**
- **Produces:**
  - `public struct ListenStat: Sendable, Hashable { public var count: Int; public var lastAt: Date? }`, in PFCore.
  - `public struct ListenRule: Sendable`, in PFCore:
    - `init(durationSeconds: Double)`;
    - `mutating func observe(positionSeconds: Double, playing: Bool, scrubbing: Bool) -> Bool`. It returns `true` exactly once: on the observation where really-played time first reaches the threshold.
    - `var threshold: Double?`: nil when the track is under 30 s.
  - `Library` (PFLibrary):
    - `public func recordListen(trackID: String, at date: Date) async -> ListenStat`;
    - `public func listenStats() async -> [String: ListenStat]`, keyed by track ID.
  - `LibraryTrack.addedAt: Date` and `LibraryAlbum.addedAt: Date`. The album's is the latest of its tracks'.
  - `public enum AlbumSort: String, CaseIterable, Sendable { case mostPlayed, recentlyPlayed, newestRelease, lastAdded, hiResFirst }`, in PFCore, with:
    - `var title: String`;
    - `public struct AlbumOrderKey: Sendable { id, title, year: Int?, addedAt: Date, listens: Int, lastListened: Date?, bits: Int, rate: Int }`;
    - `public static func ordered(_ keys: [AlbumOrderKey], by sort: AlbumSort) -> (ids: [String], fellBack: Bool)`. `fellBack` is true when `mostPlayed` had no listens and used Last added.
  - `AlbumCard` gains:
    - `let addedAt: Date`;
    - `let listens: Int`;
    - `let lastListened: Date?`;
    - `let bestBits: Int`;
    - `let bestRate: Int`.

    Update every `AlbumCard(` construction, including mocks and previews.
  - `LibraryBrowsing` gains `func albums(sortedBy sort: AlbumSort) -> (albums: [AlbumCard], fellBack: Bool)`.

**Exact values:**
- **The listen rule.**
  - `threshold = min(0.5 × duration, 240)` for `duration ≥ 30`; nil below 30 s.
  - Really-played time adds `Δ = position − lastPosition` only when all of these hold:
    - `playing` is true;
    - `scrubbing` is false;
    - `0 < Δ ≤ 1.5`.

    Larger forward jumps are seeks and add nothing. A backward step resets `lastPosition` and adds nothing.
- **Migration v5** (append to `LibraryStore.migrations`; never edit earlier ones):

  ```sql
  CREATE TABLE listens(track_id TEXT PRIMARY KEY, count INTEGER NOT NULL, last_at REAL NOT NULL);
  ```

  `recordListen` upserts `count = count + 1, last_at = <date>`. Rows survive track removal. They are harmless, and come back if the file returns.
- **Orders** (every tie broken last by `id`, ascending, for stability):

  | Sort | Order |
  |---|---|
  | `mostPlayed` | `listens` desc, `lastListened` desc (nil last), `addedAt` desc. If every key has `listens == 0`, order as `lastAdded` and set `fellBack = true`. |
  | `recentlyPlayed` | `lastListened` desc (nil last), then `addedAt` desc. |
  | `newestRelease` | `year` desc (nil last), then `title` (localized standard compare). |
  | `lastAdded` | `addedAt` desc. |
  | `hiResFirst` | `bits` desc, `rate` desc, then `title`. |

- **App wiring.** `PlaybackController` runs a `@MainActor` task while a track plays. It polls every 0.5 s, holds one `ListenRule` per current player index, and resets it when `player.currentIndex` changes or a repeat-one loop restarts the track. When `observe` returns true, it calls `library.recordListen(trackID:at:)`. `RealLibrary` then updates its album aggregates in place, without waiting for a catalog, so the next galaxy layout sees the new count.
  - Album listens = the sum of its tracks' counts.
  - `lastListened` = the max of its tracks'.

- [ ] **Step 1:** Write `ListenRuleTests`:
  - `countsOnceAtHalfTheLength`: 200 s track, positions 0, 0.5, …, 100.5 while playing → true exactly once, at the first observation ≥ 100.
  - `fourMinuteCap`: 600 s track → threshold 240.
  - `shortTracksNeverCount`: a 29 s track → never true.
  - `seeksDoNotCount`: 0 → 150 in one step → false. Then playing on from 150 needs 100 s of real time.
  - `pausedTimeDoesNotCount`: position frozen while `playing` is false → no progress.
  - `scrubbingDoesNotCount`: same, with `scrubbing` true.
  - `backwardsResets`: after 0 → 50 played, a jump to 10 → the accumulated 50 s is kept, and it continues from 10.

  Run `swift test --package-path Packages/PointFlacKit --filter ListenRuleTests` and see them fail. Implement. See them pass.
- [ ] **Step 2:** Write `AlbumOrderTests`. One test per sort covers the exact order above, including nil years and nil last-listened sorting last. Also:
  - `fallsBackToLastAddedWithNoListens`;
  - `tiesAreStableByID`.

  Fail, implement, pass.
- [ ] **Step 3:** Write `ListenStoreTests` against a temporary library, as the existing PFLibrary tests make one:
  - `recordListenCountsAndPersists`: record twice, reopen the database, and `listenStats()` shows count 2 and the last date.
  - `migrationFromV4KeepsTracks`: an existing v4 store opens and gains the table.

  Also add `addedAt` to `LibraryTrack`/`LibraryAlbum`, read from `tracks.added_at`. Fail, implement, pass.
- [ ] **Step 4:** App wiring: the `AlbumCard` fields, `RealLibrary` aggregates and `albums(sortedBy:)`, and the tracking in `PlaybackController`. Build the app:

  ```bash
  xcodebuild -project PointFlac.xcodeproj -scheme PointFlac -destination 'platform=iOS Simulator,name=pointFlac-s7' build
  ```

  Run `scripts/bootstrap.sh` first if the project is missing. Then run `PlaybackSmokeTests` and `PlayerUITests` on `pointFlac-s7` with `-only-testing:PointFlacUITests/PlayerUITests -only-testing:PointFlacUITests/PlaybackSmokeTests`.
- [ ] **Step 5:** Run `swift test --package-path Packages/PointFlacKit` (the whole package, host) and lint. Commit in logical commits, for example `feat(library): count listens` and `feat(shelf): album sort keys`.

### Task 2: Galaxy engine (pure, in PFDesign)

**Files:**
- Create: `Packages/PointFlacKit/Sources/PFDesign/GalaxyLayout.swift`.
- Create: `Packages/PointFlacKit/Sources/PFDesign/GalaxyPhysics.swift`.
- Tests:
  - `Packages/PointFlacKit/Tests/PFDesignTests/GalaxyLayoutTests.swift`;
  - `Packages/PointFlacKit/Tests/PFDesignTests/GalaxyPhysicsTests.swift`.

  Create the test target in `Package.swift` if PFDesign has none.

**Interfaces:**
- **Produces** (all `public`, `Sendable`, and only `CoreGraphics`/`Foundation`):
  - `struct GalaxyMetrics`, with defaults:
    - `coreSide = 140`;
    - `maxSide = 96`;
    - `minSide = 34`;
    - `falloff = 5.4`;
    - `gap = 14`;
    - `driftAmplitude = 4`;
    - `aspect = 1.28` (the vertical stretch of the search spiral);
    - `radialStep = 3`;
    - `arcStep = 7`;
    - `func side(rank: Int, scale: Double) -> Double`. It returns `coreSide·scale` for rank 0, else `(minSide + (maxSide − minSide)·exp(−rank/falloff))·scale`.
  - `struct GalaxyLayout { static func place(count: Int, metrics: GalaxyMetrics = .init()) -> [GalaxySlot] }`, where `GalaxySlot { center: CGPoint; side: Double }`.
    - Ranks run 0…count−1, around the origin (0, 0).
    - Rank 0 sits at the origin.
    - Each next rank takes the first free spot found by searching outward. Radius grows by `radialStep`. At radius r there are `max(10, round(2πr/arcStep))` angles, starting at `rank × 2.39996` rad. A spot is `(cos a·r, sin a·r·aspect)`.
    - A spot is free when, for every placed slot, `|dx| ≥ (sa+sb)/2 + gap` OR `|dy| ≥ (sa+sb)/2 + gap`.
    - The world is unbounded: no screen bounds, so placement always succeeds.
    - Use a uniform grid (cell = `coreSide + gap`) for the free-spot checks, so 1,000 albums place in well under 100 ms in Release.
  - `struct Drift { static func offset(seed: UInt64, time: Double) -> CGVector }`.
    - `|dx|` and `|dy|` are each ≤ `driftAmplitude`. Use `2.5·sin(0.55w+φ) + 1.5·sin(0.21w+2φ)` and the cosine analogue.
    - `w = time × speed`, with speed in [0.5, 1.1] and φ in [0, 2π), both derived from `seed` (SplitMix64).
    - Because `gap ≥ 2·driftAmplitude + 6`, drifting homes never touch.
  - `struct GalaxyPhysics`:
    - `var bodies: [Body]`, where `Body { center: CGPoint; velocity: CGVector; side: Double; held: Bool }`;
    - `mutating func step(holdTarget: CGPoint?)`, for the held body, if any;
    - `var isSettled: Bool`: every speed < 0.05 and no pair overlapping, both with `gap = 6`.
    - **Each step:**
      1. The held body moves to the target, and its velocity becomes the move.
      2. Others integrate: velocity × 0.90 damping, then position += velocity. There is no spring home: dropped and pushed sleeves stay.
      3. Four separation passes over pairs. Use a uniform grid of cell = `2·maxSide`. Push apart along the axis of least overlap, with gap 6. A held body has infinite mass; the rest share by `side²`. Pushed bodies gain 0.25 × their push as velocity, on the first pass only.

- [ ] **Step 1:** Write `GalaxyLayoutTests`:
  - `rankZeroIsAtTheCentreAndBiggest`;
  - `noTwoSlotsTouch`, across counts 1, 2, 3, 38 and 1,000, with the gap (the `|dx|`/`|dy|` rule);
  - `nearnessFollowsRank`: the mean distance from the origin of ranks 1–5 < that of ranks 30–37, for 38;
  - `sidesShrinkWithRankAndNeverGoBelowMin`;
  - `deterministic`: the same count gives the same slots;
  - `thousandAlbumsPlaceQuickly`: < 1 s in a Debug host test. This is a guard, not the budget.

  Fail, implement, pass.
- [ ] **Step 2:** Write `GalaxyPhysicsTests`:
  - `heldBodyShovesOthersWithoutOverlap`: drag the biggest body through a 38-slot layout in 60 steps, release, and step until settled (≤ 600 steps). No pair overlaps, and `isSettled`.
  - `droppedBodyStays`: after the release and settle, its centre is within 2 pt of where it was let go, plus its velocity coast.
  - `restingBodiesDoNotMove`: a laid-out galaxy with nothing held moves < 0.01 pt in 100 steps.
  - `driftNeverTouches`: for a 38 layout, offsets at 200 sample times keep every pair apart, with gap > 0.

  Fail, implement, pass.
- [ ] **Step 3:** Run `swift test --package-path Packages/PointFlacKit --filter "GalaxyLayoutTests|GalaxyPhysicsTests"` and lint. Commit: `feat(design): galaxy layout and physics`.

### Task 3: Tracklist (back-cover sheet, deck display unfold, tonearm swing)

**Files:**
- Create: `App/Player/TracklistSheet.swift`.
- Modify:
  - `App/Player/SharedControls.swift` (the song line opens the sheet);
  - `App/Player/DeckStage.swift` (display unfold, arm swing);
  - `App/Player/PlayerScreen.swift` (sheet presentation), if needed;
  - `App/Model/PlaybackController.swift` (a `jump(toTrack:)` helper), if needed.
- Test: `AppUITests/PlayerUITests.swift` (new tests).

**Interfaces:**
- **Consumes:** from `PlaybackController`:
  - `album`, `tracks: [TrackRow]` (each with `side` code and `durationSeconds`);
  - `layout: SideLayout` (sides, `letter`, track ranges);
  - `trackIndex`, `isPlaying`;
  - `play(fromTrack:at:)`.
- **Produces:**
  - `func jump(toTrack index: Int)` on `PlaybackController`. It plays the record from that track through the existing transport serialisation. If that track is on another side, the deck's existing side-change and flip behaviour runs.
  - `struct TracklistSheet: View`.

**Look (exact):**
- **Presentation.**
  - `.presentationDetents([.medium, .large])`, with the system glass background and grabber visible.
  - Opens scrolled so the playing row is visible.
- **Header row.**
  - The album `Sleeve`, 58 pt, corner 10.
  - The title in `.title3.weight(.semibold)`.
  - `artist · year` in `.subheadline` secondary.
  - Trailing: the album format, e.g. "FLAC 24/96", in `.caption.monospaced()` secondary.
- **Summary line.** `5 SONGS · 25:05 · 2 SIDES`, in `.caption2.monospaced().weight(.semibold)` with 1.2 tracking, secondary.
- **Side headers.** `SIDE A` plus the side's total time, in the same mono caption style, with a hairline (`theme.hairline`) filling the rest of the row.
- **Rows.** 46 pt tall:
  - the code (A1) in `.footnote.monospaced().weight(.semibold)` secondary, 28 pt wide;
  - the title in `.body`;
  - the duration in `.subheadline.monospacedDigit()` secondary.
- **The playing row.**
  - Background: a 14 pt-corner rounded rectangle in the album palette's line colour at 0.12 opacity (the monochrome twin in Monochrome).
  - The title semibold, in that colour darkened for contrast ≥ 4.5:1.
  - The code is replaced by 3 animated bars: 3.5 pt wide, 4–14 pt tall, 1 s ease-in-out cycle, staggered. They are static at mid height when paused or with Reduce Motion.
- **Tapping a row.**
  - `.sensoryFeedback(.selection)`, then `jump(toTrack:)`, then dismiss after 0.25 s.
  - VoiceOver: each row reads "A1, Ignition, 3 minutes 10 seconds", with "Playing" as its value when current. Activating it jumps.
- **The song line under the title.**
  - It becomes a button: the same text plus an `chevron.up` SF Symbol at 9 pt, semibold, secondary.
  - Accessibility label "Tracklist", hint "Shows the record's songs", identifier `tracklistButton`.
  - Works in Deck and Cover.
- **The deck display unfold (Deck only).**
  - Tapping `DeckScreen` (identifier `deckDisplay`) unfolds it into a `DotMatrixScreen`-styled panel. The panel covers the plinth's platter area, inset 8 pt, corner 14, using `theme.lcdInk`/`theme.lcdBack` with the existing dot texture.
  - Animation: `.spring(duration: 0.45, bounce: 0.15)`, scaling from the display's frame. With Reduce Motion it cross-fades.
  - Contents:
    - a header line `NIGHT DRIVE   5 TRK 25:05`;
    - `— SIDE A —` separators;
    - rows `A1  IGNITION  3:10`, in the dot-matrix font, upper case, 34 pt tall, scrollable. The current row is inverted (ink background, back-coloured text).
  - Tapping a row jumps and folds back. Tapping the header folds back without a jump, and so does tapping outside.
  - Identifiers: `deckTracklist`, with rows `deckTrack-<index>`.
- **The tonearm swing.** After a `jump(toTrack:)`, `armAngle` animates from its current angle to the new position's angle over 0.6 s (spring), instead of snapping. If a flip happens, the existing flip runs first and the arm drops after it.

- [ ] **Step 1:** Write the UI tests in `PlayerUITests`. Use its `launch(demoPlay: true)`, which plays the demo album Night Drive.
  - `testTracklistJumpsToLastTrack`: tap `tracklistButton`, tap the row for "Last Exit", wait ≤ 5 s, and the title label shows "Last Exit".
  - `testDeckDisplayUnfoldsAndJumps`: tap `deckDisplay`, `deckTracklist` appears, tap `deckTrack-1`, and the title shows "Neon Mile" while `deckTracklist` disappears.

  Run them on simulator `pointFlac-sui`, with `-destination 'platform=iOS Simulator,name=pointFlac-sui'` and `-only-testing` for the two. See them fail.
- [ ] **Step 2:** Implement the sheet, the song-line button, the jump helper, the display unfold and the arm swing.
- [ ] **Step 3:**
  1. Run the two tests plus all of `PlayerUITests` and `PlaybackSmokeTests` on `pointFlac-sui`.
  2. Lint.
  3. Take simulator screenshots to `/private/tmp/claude-502/-Users-kiranjose-Documents-Echocore/43622516-99f0-408b-a329-b1c4beb69ce6/scratchpad/tracklist-*.png`: the sheet in light and dark, the unfolded display, and Monochrome.
  4. Commit: `feat(player): tracklist sheet and deck display`.

### Task 4: Galaxy view in the Shelf

**Files:**
- Create: `App/Shelf/GalaxyView.swift`.
- Create: `App/Shelf/GalaxyModel.swift` (`@Observable @MainActor`: homes, fly animation, physics session, camera).
- Modify: `App/Shelf/ShelfPanel.swift` (mode switch, sort menu, hosting, hand-off from a sleeve's frame, the hold menu reusing `upNextMenu` and the delete flow).
- Test: `AppUITests/ShelfGalaxyUITests.swift`.

**Interfaces:**
- **Consumes:**
  - Task 1's `LibraryBrowsing.albums(sortedBy:)`, `AlbumSort` and `AlbumCard` fields;
  - Task 2's `GalaxyLayout`, `GalaxyMetrics`, `Drift` and `GalaxyPhysics`;
  - the existing `pick(AlbumCard, TrackRow.ID?, CGRect?)`. The rect is the tapped sleeve's on-screen frame in `.named(PlayerSpace.name)`.
- **Produces:** `ShelfMode` (`crate`/`galaxy`), stored in `@AppStorage("shelfMode")`, default `crate`. Also `@AppStorage("galaxySort")`, default `mostPlayed`.

**Behaviour (exact):**
- **Controls row.** It sits under the chips:
  - a segmented `Picker` "Crate | Galaxy" (identifier `shelfModePicker`);
  - when Galaxy, a trailing `Menu` labelled with the current sort title and an `arrow.up.arrow.down` symbol (identifier `galaxySortMenu`), listing the five sorts with a checkmark on the current one.
- **The galaxy area.**
  - It fills the panel below the controls, down to the panel's bottom, and is clipped.
  - Background: a radial glow in the centre album's `ArtPalette` colour at 0.55 opacity, blurred 60. It uses the monochrome twin in Monochrome, and cross-fades over 1.6 s when the centre album changes.
- **Rendering.**
  - `TimelineView(.animation)`, paused when Reduce Motion is on and nothing is moving.
  - `Canvas` with `symbols:` — one `Sleeve(album:)` per album at `coreSide`, tagged by album ID — each drawn at its current side, at home + drift offset. Draw them big last.
  - A shadow per sleeve, `radius 10, y 6, opacity 0.35`, drawn in the canvas.
- **Layout.**
  - On appear, on switching to Galaxy, on a sort change, on a filter-chip change, and when the album set changes: compute `GalaxyLayout.place(count:)` for `albums(sortedBy:)` (filtered as `crateAlbums` is).
  - Map rank to slot.
  - The camera starts centred on the origin, at the scale that fits the whole layout in the area, clamped to 0.55…1.0.
- **The fresh-arrangement rule.** Re-entering always lays out fresh, discarding dropped positions. A sort change flies:
  - each sleeve moves from its current to its new centre and side, eased in-out cubic over 1.1 s;
  - staggered by `min(14 ms, 600 ms / n)` per rank;
  - its side dips by up to 38% mid-flight (× `1 − 0.38·sin(πp)`);
  - collisions are off until every flight ends.

  With Reduce Motion, sleeves cross-fade (0.25 s) into the new layout instead.
- **Gestures**, all in canvas space, hit-tested topmost (biggest drawn last) first:
  - **Touch on a sleeve, release within 8 pt and before 0.45 s:** tap → `pick(album, nil, frame)` with that sleeve's frame in player space. This is the existing hand-off; hide that sleeve while `hidesFront`-equivalent is set, so there is never a double.
  - **Touch on a sleeve and move ≥ 8 pt:** drag. A `GalaxyPhysics` session runs until settled. On settle, homes become the bodies' centres.
  - **Touch on a sleeve and hold 0.45 s without moving:** haptic `.impact(weight: .medium)`, then a `confirmationDialog` titled with the album. It offers Play, Play Next, Add to Up Next and Delete… (destructive), reusing ShelfPanel's existing up-next and delete flows.
  - **Touch on empty space and drag:** pan the camera.
  - **`MagnifyGesture`:** zoom 0.5…2.0, anchored at the pinch location.
- **Most played with no history.** A quiet `.footnote` secondary line at the galaxy's top: "No listening history yet. Sized by Last added." (identifier `galaxyFallbackNote`).
- **Query typed.** While the search query is non-empty, show the Shelf's normal results list, as in Crate mode, not the galaxy.
- **Accessibility.**
  - `.accessibilityChildren` gives one element per album in rank order: label "<title>, <artist>"; value "<n> plays" when sorted by Most played, else the sort's attribute.
  - Default action: pick (Reduce Motion path if set). Custom actions: "Play Next" and "Add to Up Next".
  - Identifiers `galaxy-<rank>`. The container's identifier is `shelfGalaxy`.
- **Performance.**
  - Placement for more than 200 albums runs off the main actor (`Task.detached`). Show the previous layout until it's ready.
  - Resting frames do no physics: drift is analytic.
  - It must hold 120 Hz with 300+ albums on device.

- [ ] **Step 1:** Write `ShelfGalaxyUITests`. Use `XCUIApplication.pointFlac(["-PFPreloadFixtures", "-PFOpenShelf"])` plus a debug launch argument `-PFShelfMode galaxy`; add it, DEBUG only.
  - `testGalaxyShowsAllAlbumsAndSorts`: the `shelfGalaxy` element exists, with 5 `galaxy-*` children (the demo library has 5 albums). Open `galaxySortMenu`, choose "Newest release", and `galaxy-0` still exists. Then choose "Hi-res first", and `galaxy-0`'s label contains "Hydrophone" (the 24/96 32-bit album; check it against the fixtures and adjust).
  - `testTappingASleevePlaysIt`: tap `galaxy-0`; within 6 s the player's title shows that album's first track.
  - `testFallbackNoteWithoutHistory`: with a fresh library, sorted Most played, `galaxyFallbackNote` exists.

  Run on simulator `pointFlac-s16` with `-only-testing`. See them fail.
- [ ] **Step 2:** Implement `GalaxyModel`, `GalaxyView` and the `ShelfPanel` integration.
- [ ] **Step 3:**
  1. Run the new tests and the existing `PlayerUITests` (which open the shelf) on `pointFlac-s16`.
  2. Lint, and run the host package tests.
  3. Screenshots to the scratchpad as `galaxy-*.png`: light, dark, Monochrome, a sort change caught mid-flight, and a sleeve being dragged (if capturable).
  4. Commit: `feat(shelf): galaxy mode`.

### Task 5: Integrate and verify

- [ ] Merge the Task 1–4 branches into `feat/galaxy-tracklist` (worktree `.worktrees/galaxy`), resolving conflicts.
- [ ] Run the full `PF_SIM_NAME=pointFlac-s1415 scripts/test.sh` once, with the machine otherwise idle. Fix any failures and re-run the affected stage.
- [ ] Record the results in the ledger. Do not push. The owner decides on push, PR and phone install.
