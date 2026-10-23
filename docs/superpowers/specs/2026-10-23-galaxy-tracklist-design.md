# pointFlac: Shelf Galaxy and the Tracklist (design)

**Date:** 2026-10-23
**Owner:** Kiran P Jose. Kiran decided everything stated plainly here, in the brainstorm of 2026-10-23, reacting to live mockups. Calls Claude made are marked **[call]**. Kiran approved them as a whole ("cool go ahead", then "just build it").

## 1. Intent

Two additions:

- **A Galaxy mode for the Shelf.** It is mostly for picking what to play next, and it must look stunning. Albums float as solid, scattered sleeves. The more you listen to an album, the bigger it is and the nearer the centre.
- **A Tracklist** for jumping to any song of the record on the deck, without using the tonearm.

## 2. Galaxy

### Look and layout

- **Mode switch.** The Shelf gets a **Crate | Galaxy** switch, with a **Sort** menu beside it while Galaxy is showing. The choice of mode and sort persists. Crate is the default. **[call]**
- **No overlaps.** Every album is a solid sleeve.
  - Sleeves never overlap at rest.
  - They collide when moved.
  - They sit scattered, with gaps between them.
- **Size and position follow the sort.**
  - The first album in the current sort is the biggest, at the centre.
  - The rest take the free spot nearest the middle, in order. They get smaller as they go out.
- **Motion and glow.**
  - Every sleeve drifts slowly, bobbing a few points.
  - Drift never makes two sleeves touch.
  - A soft glow behind the galaxy takes the centre album's colour.

### Sorts

| Sort | Order |
|---|---|
| Most played | Listen count, highest first |
| Recently played | Last listened, newest first |
| Newest release | Album year, newest first |
| Last added | Newest addition first |
| Hi-res first | Most bits first, then highest rate |

- Changing the sort makes every sleeve glide to its new size and place.
- During the glide, sleeves shrink a little so they pass each other. Collisions are off until they land.

### Touch

- **Dragging a sleeve** moves it, and it shoves the others aside.
  - **Where it is dropped, it stays.** The sleeves it pushed stay where they ended up too.
  - Nothing drifts back on its own.
- **Coming back gives a fresh arrangement.** It happens each time the galaxy appears: the Shelf opened in Galaxy mode, or a switch from Crate to Galaxy. It also happens when the sort changes.
- **Tapping a sleeve plays it** with the crate's hand-off animation:
  1. the shelf sinks;
  2. the sleeve flies;
  3. the record lands on the spindle;
  4. the platter spins up;
  5. the needle drops.

  This is the same hand-off the crate uses, starting from the tapped sleeve's frame.
- **Holding a sleeve** offers the crate's actions: Play Next, Add to Up Next and Delete. **[call]**
- **No info card.** There is no bottom info card; a tap plays. **[call]**
- **Big libraries** spread past the screen. Drag empty space to pan; pinch to zoom. **[call]**
- **The smallest sleeve** stays big enough to tap, 34 pt or more. **[call]**

### Listen history (new)

pointFlac doesn't count listens today, and iOS gives an app no play counts for files, so counting starts with this update.

- **What counts as a listen.** A track counts once it has really played half its length or 4 minutes, whichever comes first. Tracks under 30 s never count. This is the common scrobbling rule. **[call]**
- **What does not count.** Time skipped by seeking or scrubbing does not count toward that threshold.
- **Album figures.** An album's plays are the total listens of its tracks. Its last-listened time is the latest of its tracks'.
- **No history yet.** While nothing has been listened to, Most played orders by Last added and says so in one quiet line.

### Search and filters

- The filter chips (24-bit+, 32-bit, ≥96 kHz and so on) narrow the galaxy, which re-forms.
- Typing a query shows the Shelf's normal search results, as in Crate mode. **[call]**

### Settings it respects

- **Monochrome.** The glow goes grey; artwork stays in colour.
- **Reduce Motion.** No drift, and sort changes cross-fade instead of gliding.
- **VoiceOver.** Every album is an element, in sort order. Activating one plays it. Play Next and Add to Up Next are custom actions.
- **Smoothness.** It must hold 120 Hz on an iPhone 17 Pro with several hundred albums.

## 3. Tracklist

Kiran chose option B from the mockups: the back-cover sheet, plus the deck's display.

### The back-cover sheet

- **Opening it.** It opens from the song line under the title (`<artist> · Side A · Track 1`), in Deck and Cover alike. That line shows a small chevron.
- **What it shows,** laid out like the back of the sleeve:
  - a header: the sleeve, the album title, `artist · year`, and the format;
  - a summary line: song count, total time and side count;
  - songs grouped by side (`SIDE A  10:05`), with codes (A1, B2), titles and exact times;
  - the playing song tinted, with moving bars in place of its code.
- **Tapping a song** jumps to it, and the sheet drops.

### The deck's display (Deck only)

- Tapping the dot-matrix display unfolds it over the platter into a dot-matrix tracklist.
- The rows read like `A1 IGNITION 3:10`, and the playing row is inverted.
- Picking a song plays it, and the display folds back.

### Jumping

- Choosing a song plays the record from that song.
- On the Deck, the tonearm **swings** to that song's groove instead of snapping there.

## 4. Non-goals

- No listen history from before this update.
- No editing of the tracklist.
- No galaxy for songs: albums only.
