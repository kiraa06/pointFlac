# Playlists as custom pressings: design

**Ask (Kiran, 2026-11-11):** "Custom Playlist Vinyl: a user-made album disc that the user can add liked songs to from any album. A default Fav album, plus the option to create others with whatever names they need. You decide all the design things. Make sure it's stunning and matches our design."

Every design call below is the controller's, made on Kiran's instruction to decide them.

## 1. Intent

pointFlac treats music as records: sleeves in a crate, sides, a deck. A playlist should feel like a record you had pressed yourself, not like a list in a database. Each playlist is its own **custom pressing**:
- a coloured vinyl in a colour you pick;
- a label made from the covers of the albums its songs come from;
- your title curved around the rim.

It sits beside the albums on the shelf, flies to the deck the same way, and plays like any record: sides, tracklist, tonearm, Up Next.

**Goals.**
- **Favourites, always there.** It is created on first launch and can't be deleted or renamed.
- **Any number of named playlists.** Create, rename, recolour and delete.
- **Add songs from anywhere:**
  - the heart on the player (current song);
  - the tracklist (any song);
  - the shelf (an album, or a song in the search results).
- **Play a playlist exactly like an album:** the hand-off, the deck, the cover view, the tracklist, Up Next, the lock screen (each song keeps its own album art there).
- **Stunning:** the pressing art is the centrepiece and must look like a real pressing at deck size and at 56 pt.

**Non-goals for v1.** Smart playlists, shuffle, sharing or exporting, folders of playlists, playlists inside the galaxy, and editing the queue of a playlist that is already playing (edits apply the next time it is put on the deck).

**Anti-goals.**
- Anything that deletes a song file. Deleting a playlist or removing a song from one never touches files or the library.
- A pressing that looks like a flat app icon.

## 2. Names and words

- **Playlist** for the thing: "Add to Playlist…", "New Playlist", "Delete Playlist…".
- **Favourites** (British spelling) for the default playlist.
- **Heart** for the favourite toggle, with VoiceOver labels "Add to Favourites" / "Remove from Favourites".
- **Delete Playlist** confirmation: "Deletes this playlist. The songs stay in your library." Button: "Delete Playlist".
- **Empty playlist line:** "No songs yet. Tap ♥ on the player, or long-press any album or song to add it."

## 3. The pressing (art)

Everything is drawn from code in the app's style, with no bundled images.

### Vinyl
- Translucent coloured vinyl, drawn the way `RecordStyle.coloured` draws it today: grooves, the platter faintly through it, the fixed light streaks, and the dead wax. The tint is the playlist's **pressing colour**, not the album palette.
- A playlist always shows its pressing colour, whatever the global record style (black, coloured or picture). The colour is the playlist's identity.
- Monochrome turns it grey, as every other interface colour does.

### Pressing colours
Eight, in the picker in this order:

| Colour | Hex |
|---|---|
| Ruby | `#C2203A` |
| Amber | `#E08A1E` |
| Citrine | `#D9B43A` |
| Jade | `#1E9E74` |
| Ocean | `#1F6FB8` |
| Violet | `#7A4FD1` |
| Smoke | `#8C8F96` (clear, smoky) |
| Onyx | `#1A1A1E` (black) |

- Favourites is Ruby by default.
- A new playlist takes the next colour in the order Amber, Jade, Ocean, Violet, Citrine, Smoke, Onyx, Ruby, skipping colours already in use while any are free.

### Label
The label is `labelToRecord`, a real 100 mm label on a 302 mm record. From the outside in:
1. **Paper rim ring** from 0.80 to 1.0 of the label radius:
   - cream paper, `#F2EBDD`, with a faint paper grain;
   - curved rim text in small caps, in dark ink `#2B2A27`: `FAVOURITES · 24 SONGS · SIDE A · 33⅓ RPM`, using the existing `RecordPrint.arc` routine.
2. **Cover wedges** from 0.24 to 0.80:
   - The covers of up to 6 distinct albums, in playlist order, each in an equal wedge radiating from the centre, with hairline cream gaps (1 pt at deck size).
   - 1 album: a full disc. 2: halves. 3–6: equal wedges.
   - A soft radial vignette joins them.
   - Covers stay in colour even in Monochrome, as album artwork always does.
3. **Centre badge** from 0 to 0.24:
   - A cream disc with a thin ring in the pressing colour.
   - Favourites: a solid heart in the pressing colour.
   - Other playlists: a monogram (the initials of the first two words, upper-case, in a bold serif), in the pressing colour.
   - The spindle hole is in the middle.
4. **Empty playlist:** the wedge area is cream paper with fine concentric guilloché rings in the pressing colour at 25 % opacity. The badge stays.

### Dead wax and the deck display
- **Matrix** etched in the dead wax: Favourites `PFL-FAV-A1`; other playlists `PFL-MIX-<first 4 of id>-A1` (the side letter changes the `A`).
- **Deck display** when idle: `FAVOURITES·24 SONGS`. While playing, each song shows its own title·artist, as today.

### Three sizes
- **The deck record:** the full detail above.
- **The shelf disc** (56–64 pt): the same art, simplified so it reads small:
  - grooves drawn as 6–8 sheen rings;
  - no rim text, but the badge and the wedges stay;
  - a soft drop shadow and a fixed highlight.
- **The cover view** (`CoverStage`):
  - When a playlist is on the deck, the big square shows the **current song's own album cover**, which changes with each song, with the pressing peeking out beside it as today's record does.
  - The playlist's title and song count sit in the caption.

### Motion
- **Creating a playlist:** the new disc "presses" in, scaling from 0.85 to 1.0 with a spring, the label fading in 80 ms later, and a soft impact haptic.
- **Hearting:** `heart` to `heart.fill` with a bounce symbol effect, and a medium impact.
- **Adding a song in the Add to Playlist sheet:** that row's disc turns a quarter turn, with a selection haptic.
- **Reduce Motion:** cross-fades only.

## 4. Where things live

### Shelf: a Playlists strip
- At the top of the shelf panel, under the search and mode controls and above the crate or galaxy, a horizontal strip headed "Playlists":
  - first a **New** disc: a dashed circle with a plus, identifier `newPlaylistButton`;
  - then Favourites;
  - then the other playlists in the order they were created.
- **Each item** is the shelf disc with the name under it in `.caption` (one line, truncated) and the song count in `.caption2`, secondary.
- **Tap** a playlist with songs: the same hand-off as an album, except the disc flies itself, with no sleeve sinking.
- **Tap** an empty playlist: its playlist sheet opens.
- **Long-press:**
  - Play
  - Play Next
  - Add to Up Next
  - Open Playlist
  - divider
  - Delete Playlist… (not offered for Favourites)
- **Hidden while searching.** Search results gain a "Playlists" section when names match.
- **Strip height** is about 96 pt, so the crate keeps its room. With Dynamic Type at accessibility sizes, the captions wrap to two lines and the strip grows.

### Player: the heart
- A heart button joins the player's shared controls next to the Up Next and tracklist buttons, identifier `favouriteButton`.
- It toggles the current song in Favourites.
- Filled and tinted Ruby when the song is in Favourites (grey in Monochrome), with the `.isSelected` trait.
- Disabled when nothing is playing.

### Tracklist (sheet and deck display)
Long-pressing a song row opens a menu:
- Add to Favourites / Remove from Favourites
- Add to Playlist…
- Remove from This Playlist (only while a playlist is on the deck)

### Shelf album and search results
- **Album menu:** add "Add to Playlist…", which adds the album's songs in order and skips any already there.
- **Song result menu:** add "Add to Favourites" and "Add to Playlist…" for that song, not its album.

### Add to Playlist sheet
- A medium-detent sheet, title "Add to Playlist", identifier `addToPlaylistSheet`.
- First row: "New Playlist…".
- Then one row per playlist: a small disc, the name, the song count, and a checkmark when every song being added is already in it.
- Tapping a row adds the songs (toggling one song off if it is already there), with the disc's quarter turn, then closes after 350 ms.
- Rows are `addToPlaylist-<id>`.

### New Playlist sheet
- Header "New Playlist", with a live pressing preview at 180 pt.
- A name field, default "New Playlist", "New Playlist 2", … (1–60 characters, trimmed, never empty).
- The eight colour swatches, drawn as small vinyl discs, each with an accessibility label of its colour name, identifiers `pressingColour-<id>`.
- A "Create" button (`.glassProminent`).
- Opened from New on the strip, or from "New Playlist…" in the add sheet; from the add sheet, it creates the playlist and adds the songs.

### Playlist sheet (open or edit)
- A large pressing preview, which turns slowly at 33⅓ unless Reduce Motion is on.
- The name: Favourites shows it as plain text; other playlists show an editable field.
- The colour swatches.
- A Play button.
- The songs: each row has a 40 pt album cover, the title, "artist · album", and the duration.
  - Swipe left to remove.
  - An Edit button turns on drag-to-reorder.
- "Delete Playlist…" at the bottom, except for Favourites.
- Identifiers: `playlistSheet`, `playlistName`, `playPlaylist`, `playlistSong-<i>`, `deletePlaylist`.

## 5. Data

### Storage
Migration v6 adds two tables:
- `playlists(id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL, colour TEXT NOT NULL, created_at REAL NOT NULL)`, where `kind` is `favourites` or `custom`.
- `playlist_tracks(playlist_id TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE, track_id TEXT NOT NULL, position INTEGER NOT NULL, added_at REAL NOT NULL, PRIMARY KEY (playlist_id, track_id))`.
- The migration also seeds Favourites with the fixed ID `favourites`.

### Soft track references
`track_id` is a soft reference with no foreign key, like `listens`, because:
- a song whose file is briefly missing (iCloud, an unreachable folder) must come back into its playlists when the file returns, and track IDs survive moves;
- reads filter to tracks in the current catalog.

A song the user **deletes** (`remove(trackIDs:)`, including a move to Recently Deleted) is pruned from every playlist in the same transaction.

### Rules
- A song appears at most once in a playlist.
- Adding appends at the end.
- Reordering rewrites the positions.

### Library API
- In PFLibrary, playlist reads and writes run on the store queue and don't republish the catalog.
- The app keeps its own observable copy of the playlists, updated after every call.

### Playlist IDs
The app shows a playlist to the player as an `AlbumCard` with the ID `playlist:<playlist id>`, where the playlist ID is `favourites` or a lower-case UUID. Its `pressing` field carries the look. `RealLibrary.tracks(of:)` and the up-next and hand-off code resolve it through the playlist, so sides, the tracklist, Up Next, the listen tracker and the lock screen work unchanged.

## 6. Accessibility
- Every disc is a Button labelled "<name>, playlist, <n> songs", with the hint "Plays on the deck".
- Decorative art is hidden from VoiceOver.
- The colour swatches announce their names and are selectable.
- Dynamic Type never truncates the strip's names to nothing; the strip grows instead.

## 7. Left to the builder
- Exact sheen and vignette values, and the guilloché density.
- The disc shadow.
- The spring constants.
- Small layout spacing, within the existing shelf metrics.
