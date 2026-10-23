# Customize Deck Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Let the listener choose one of eight original turntable designs, and the record's style (black vinyl by default, coloured, or picture disc). Redraw the deck far more intricately and true to life.

**Architecture:**
- `PFDesign/DeckDesign.swift` holds the eight designs as data, plus `RecordStyle` and `VinylGeometry`, the real LP proportions. It is already committed.
- The app draws every design from code in `App/Deck/`, and `DeckStage` composes it.
- Static layers are rasterised once. Per frame, only the record's rotation, the arm and the strobe phase change.
- Choices persist in `@AppStorage`, under the keys in `App/Deck/DeckPreferences.swift`.
- A Customize deck screen in Settings shows `DeckPreview` cards.

**Design source:**
- The owner approved the live mockup at `/Users/kiranjose/Documents/Echocore/.superpowers/brainstorm/65526-1792738172/content/decks.html`, with all eight designs and black vinyl as the default.
- Research, real proportions and pitfalls: `/Users/kiranjose/Documents/Echocore/.superpowers/research/turntable-anatomy.md` and `turntable-themes.md`.

## Global Constraints

- **Language and lint.** Swift 6 strict concurrency, and `swift format lint --strict --recursive App AppUITests Packages` stays clean.
- **No brands.** No brand names, logos or model numbers anywhere, including text drawn on the deck.
- **Colour.**
  - Design colours go through `DeckColors`: greys in Monochrome. Album artwork always stays in colour.
  - Glasshouse follows light and dark as today's deck does; every other design keeps its own palette in both.
- **Accessibility.**
  - Every control has an accessibility label.
  - Decorative furniture is hidden from VoiceOver.
  - Reduce Motion is respected.
  - Dynamic Type must not break the layout.
- **Existing behaviour.** Keep every existing deck behaviour and accessibility identifier: tonearm drag-seek with snapping and the loupe, jog scrub, tap-record flip, tap-tonearm drop, the deck display unfolding into the tracklist (`deckDisplay`, `deckTracklist`), the hand-off landing, the tonearm swing, and `deckRecord`.
- **Audio.** Never touch the audio render thread.
- **Commits.**
  - Conventional Commits, as `Kiran P Jose <kiran.p.jose02@gmail.com>`, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
  - Never push. No subagents.
- **Machine discipline.** Use only your own simulator and your own `-derivedDataPath`, as named in your brief.

---

### Task A: Draw the deck in every design

**Owns:**
- `App/Player/DeckStage.swift`, including `DeckLayout`;
- new files under `App/Deck/`, except `DeckColors.swift` and `DeckPreferences.swift`, which you may only read;
- `App/Deck/DeckPreview.swift`: replace the placeholder body and keep its signature;
- `App/Player/CoverStage.swift`;
- the hand-off overlay's record, in `HandoffDirector.swift` and wherever `HandoffOverlay` lives;
- `PFDesign` arm geometry, with tests in `Packages/PointFlacKit/Tests/PFDesignTests/`.

**Exact requirements:**
- **Proportions** (`VinylGeometry`):
  - Platter = record × `platterToRecord`, or × `massPlatterToRecord` for `.massBlack`.
  - Label = record × `labelToRecord`.
  - Grooves run from `innerGrooveToRecord` to `outerGrooveToRecord`, and the arm's lead-in and run-out land on exactly those radii. That replaces today's 0.93 and 0.42.
- **Pivoted arms** (S, J and straight):
  - Arm length = pivot-to-spindle + `overhangToRecord` × record radius.
  - The headshell turns `offsetAngleDegrees` toward the spindle.
  - Draw a pivot housing, a counterweight behind the pivot, an anti-skate dial, a cue lever, an arm rest off the record, a headshell with a finger lift, and the cartridge in `design.cartridge`.
  - The shadow tightens as the arm lowers and spreads when it lifts.
- **The linear arm.** A rail along a radius, with a carriage and a short arm down to the stylus. Dragging the carriage along the rail seeks: fraction ↔ radius, with the same snapping and loupe as the pivoted arm. The tap-to-drop and swing behaviours map onto the carriage sliding.
- **Records** (`RecordStyle`, read from `@AppStorage(DeckPreferences.recordStyleKey)`):
  - `black`, the default:
    - near-black vinyl with fine groove rings, of slightly varying brightness, from the inner to the outer groove radius;
    - smooth gaps at the existing track `bands`;
    - a lead-in bead at the rim;
    - dead wax between the inner groove and the label, with a small etched matrix line (e.g. `PFL-<first 4 of album id>-A1`);
    - the label, which is the album artwork (`ArtworkView`) clipped to a circle. Curved rim text reads `SIDE <letter> · <ALBUM> · <ARTIST> · 33⅓ RPM · STEREO`, in small caps-style type.
    - the spindle hole.
  - `coloured`: translucent vinyl tinted from the album's `ArtPalette`, with the platter faintly visible through it, grooves and the label.
  - `picture`: today's picture disc (art over the whole record), with grooves.
- **Light streaks.**
  - Two soft highlight wedges at fixed screen angles, roughly opposite (AngularGradient or similar), over the record and weaker on the label.
  - They do NOT rotate with the record.
  - The platter's conic brushed finish is also fixed.
- **Rotation.** Clockwise at 33⅓, using the existing `SpinModel` unchanged.
- **Plinths.** All seven kinds, each with:
  - a material texture: brushed lines, wood grain, matte grain, lacquer with ash cheeks and a clear-lid reflection, smoked acrylic with refractive edges, leatherette with stitching, or frosted glass;
  - a bevel and an edge in `plinthEdge`;
  - an ambient shadow and the platter-well shadow.
- **Platters.** All five finishes. When `design.strobe` is set, draw the four strobe rows (`VinylGeometry.strobeRows`) on the rim:
  - the 33⅓ rows look still at speed;
  - the 45 rows creep slowly while playing, at a phase drift proportional to the speed difference;
  - nothing creeps while stopped.

  Mats: all five kinds.
- **Controls** (all seven layouts):
  - Placed clear of the arm's sweep and the display.
  - The `dj` layout's start/stop button toggles play and pause (label "Start/Stop", identifier `deckStartStop`), and its lamp lights while playing.
  - Everything else is decorative and hidden from VoiceOver.
- **The display.** Every design keeps the dot-matrix display band, in `design.display` ink and back. Glasshouse uses the theme's `lcdInk`/`lcdBack`, exactly as today. The tracklist unfold works in every design.
- **Settings and screens.**
  - Read the design from `@AppStorage(DeckPreferences.designKey)`. Changing it updates the deck live, with a gentle cross-fade.
  - `DeckPreview(design:recordStyle:album:)` renders the same components, still, with the needle resting a little way into side A.
  - The hand-off overlay and `CoverStage` draw the record with the current `RecordStyle`, so what flies is what lands.
- **Performance.**
  - Rasterise the plinth, platter base, mat and record art once per (design, size, style, album). Use `drawingGroup` or `ImageRenderer`, or cache an `Image`.
  - Per frame, only rotate the record layer, draw the arm, and move the strobe phase.
  - The `TimelineView` still pauses at rest.
  - It must hold 120 Hz.

- [ ] **Step 1:** Write the PFDesign tests first.
  - The pivoted arm's needle lands on the outer and inner groove radii within 0.5 % of the record radius.
  - Arm length = pivot distance + overhang.
  - The headshell angle differs from the arm line by `offsetAngleDegrees`, toward the spindle.
  - For the linear arm, fraction 0 maps to the outer groove radius, 1 to the inner, and the mapping is monotonic.

  See them fail, then implement the geometry.
- [ ] **Step 2:** Write `AppUITests/DeckDesignUITests.swift`. For `studioSilver`, `walnut` and `linear`:
  - launch with `-PFPreloadFixtures -PFStage deck -PFDemoPlay -deckDesign <id>`;
  - assert `deckRecord` and `deckDisplay` exist;
  - drag the tonearm or carriage, and the elapsed time changes;
  - on `studioSilver` only, tapping `deckStartStop` pauses.

  Simulator `pointFlac-s7`, derived data `scratchpad/dd-deckA`.
- [ ] **Step 3:** Implement the rendering. Then run the new tests, all of `PlayerUITests`, and `PlaybackSmokeTests`.
- [ ] **Step 4:** Take screenshots to `scratchpad/deck-<id>.png` for every design in light. Add Glasshouse in dark, Studio Silver with the coloured record and with the picture disc, and Walnut in Monochrome. Look at each one and fix what looks fake or cramped against the research's pitfalls list. Then lint and commit.

### Task B: The Customize deck screen

**Owns:**
- the new `App/Settings/CustomizeDeckView.swift`;
- the row in `App/Settings/SettingsView.swift`;
- the new `AppUITests/CustomizeDeckUITests.swift`.

It must NOT edit anything under `App/Deck/` or `App/Player/`.

**Exact requirements:**
- **Settings row.** Under Appearance, add a NavigationLink "Customize deck" (identifier `customizeDeckLink`). Its value shows the current design's name.
- **The screen,** titled "Customize deck":
  - At the top, a large `DeckPreview` of the selected design and record style, inside the glass card style the Sound tab uses.
  - A "Player" section: a 2-column grid of all eight designs from `DeckDesign.catalogue`.
    - Each card shows a `DeckPreview`, the name in `.subheadline.weight(.semibold)` and the tagline in `.caption`, secondary.
    - The selected card has a 2 pt outline in the theme's ink at 0.85, a checkmark symbol, and the `.isSelected` trait. No pill badges.
    - Tapping a card selects it, with `.sensoryFeedback(.selection)`, and saves it with `@AppStorage(DeckPreferences.designKey)`.
    - Identifiers `deckDesign-<id>`.
  - A "Record" section:
    - a segmented `Picker`: Black vinyl, Coloured and Picture disc (identifier `recordStylePicker`), saved with `@AppStorage(DeckPreferences.recordStyleKey)`;
    - the footer: "Black vinyl turns as calmly as a real LP. Picture disc prints the album across the whole record."
  - The selected design's blurb as a footnote under the grid.
  - Colours come from the theme and respect Monochrome. Dynamic Type must not break the grid: it drops to 1 column at accessibility sizes.
- **Accessibility.** Each card is a Button labelled "<name>, <tagline>".

- [ ] **Step 1:** Write `testCustomizeDeckPersists` (simulator `pointFlac-sui`, derived data `scratchpad/dd-deckB`):
  1. open Settings, then `customizeDeckLink`;
  2. tap `deckDesign-walnut`;
  3. pick "Picture disc" in `recordStylePicker`;
  4. terminate and relaunch;
  5. reopen the screen; `deckDesign-walnut` is selected and the picker shows Picture disc.

  See it fail.
- [ ] **Step 2:** Implement against the placeholder `DeckPreview`. Its signature is final, and Task A replaces its body. Run the test and the existing Settings-related UI tests.
- [ ] **Step 3:** Take screenshots of the screen in light, dark and Monochrome to `scratchpad/customize-*.png`. Lint, then commit.

### Task C: Integrate

- [ ] Merge A and B into `feat/deck-designs`.
- [ ] Re-take the Customize deck screenshots with the real previews.
- [ ] Run the full `scripts/test.sh` on `pointFlac-s1415`.
- [ ] Do not push; the owner decides.
