# Plan 3: the player UI (overnight stream D)

**Goal:** replace Plan 1's debug UI with the real app: Deck and Cover players in four looks, the Shelf with its crate
and the crate→deck hand-off, Get Music and Downloads, and a minimal Settings that keeps the debug views reachable.

**Binding:** spec §4.1–§4.7, §4.9 and §5.7; the shared contract (`scratchpad/overnight/common.md`), contracts 2 and 3.

## Architecture

- `PFDesign` (new package target, Foundation only, host-tested): the deck's maths, so the views stay thin.
  - `SideLayout`: splits an album into sides (≤ 22 min, never splits a track, balanced, ≥ 2 sides for ≥ 2 tracks).
  - `SpinModel`: the platter angle at a time, with spin-up and wind-down ramps (33⅓ rpm = 1.8 s a turn).
  - `TonearmGeometry`: needle angle ↔ time on the side, with snapping to track gaps.
  - `JogMath`: finger angle deltas → seconds (one turn = 1.8 s), unwrapped across ±180°.
  - `HandoffTimeline`: the §4.5 step table at Slow-mo ×3, as progress values for a time.
  - `ClockFormat` and `MatchHighlighter` (ranges for search highlighting, case and accent blind).
- `App/Model/Contracts.swift`: contracts 2 and 3, verbatim, plus `RemoteResultRow.licence` (optional, defaulted).
- `App/Model/Mock*.swift`: `MockLibrary` (over the import inbox and the bundled fixtures, so it really plays) and
  `MockMusicFinder` (fake remote rows, suggestions in two waves, a simulated download). The controller swaps in the
  real ones at integration; the UI only sees the protocols.
- `App/Model/PlaybackController.swift`: the album on the deck, its sides, Up Next and repeat, over the real `Player`.
  The player plays the whole album as one queue, so sides carry on gaplessly; at the end of the queue the controller
  pulls the next Up Next record, or replays under repeat.
- Views: `RootView` (tabs: Player, Get Music, Downloads, Settings), `PlayerScreen` (switcher, stage, shared
  controls), `DeckStage`, `CoverStage`, `ShelfPanel` + `CrateView` (in the player, so the hand-off has one coordinate
  space), `HandoffOverlay`, `GetMusicView`, `DownloadsView`, `SettingsView` (appearance, Diagnostics, Licences).
- `Theme`: colour, type and material tokens for the four looks; the System/Light/Dark override in `AppSettings`.

## Tasks

1. PFDesign target and its tests (TDD): side layout, spin, tonearm, jog, hand-off timeline, highlighting.
2. Contracts and mocks; demo fixtures (`App/Debug/make-demo-fixtures.sh`, silent, tagged, Debug only per R4).
3. App shell: tabs, theme, appearance override; Settings → Diagnostics hosts the Plan 1 debug views unchanged.
4. Player: shared controls (title, side line, signal strip cells with id `signalStrip`, progress, transport, Up Next,
   repeat), Cover stage, Deck stage (platter on a `TimelineView`, tonearm drag-to-seek with loupe and gap snapping,
   platter jog applied on release), the Deck/Cover switch.
5. Shelf: search as you type, filter chips, crate with snapping, results, Files import, the hand-off.
6. Get Music (suggestions, provider switch, results, licence) and Downloads (progress and states).
7. UI tests; screenshots of the four looks; lint; commit.

## Tests

- Host (Swift Testing, `PFDesignTests`): every PFDesign type.
- UI (XCTest, iPhone 17 Pro Max): the Plan 1 smoke tests (now via Settings → Diagnostics); tab navigation; Shelf
  search shows results; Deck/Cover switch; tonearm drag moves the position; Get Music suggestions appear; a mock
  download progresses in Downloads.

## Out of scope tonight

Audible scrub, hold-to-stop, grabbing the record mid-flight, Friday Drops, pause/resume/retry on downloads (no
contract API), the welcome screen (the first-run empty state carries the calls to action), bundled fonts (system
grotesk, mono and a drawn dot-matrix stand in), real waveform peaks in the loupe.
