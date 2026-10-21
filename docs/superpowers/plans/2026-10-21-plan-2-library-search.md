# Plan 2: library and instant local search (overnight soft-launch scope)

Spec §4.6, §4.7 (local import), §5.1, §5.4, §5.5, §5.8, §8. Entry gates from the Plan 1 hand-off are tasks 1 and 5.

**Goal:** a persistent, incremental FLAC library and an in-memory search index that answers a keystroke in well under
one 120 Hz frame (8 ms) at 10k tracks, behind a thin snapshot API the UI adapter maps onto contract 2.

**Layering (spec §5.1: features depend only on PFCore):**

```
PFCore     LibraryTrack, LibraryAlbum, LibraryCatalog (immutable value snapshot), AlbumGrouping
PFLibrary  ImportInbox (gated), LibraryDatabase (system SQLite3), LibraryScanner, ArtworkStore, Library (facade)
PFSearch   TextFolding, SearchIndex, LibrarySnapshot (catalog + index), SearchFilter, LibraryHit
PFAudio    QueueItem(track:artwork:)  (one convenience init; PFLibrary never imports PFAudio)
```

**Storage choice:** the system SQLite3 (public domain, ships in the OS) through a ~150-line wrapper, not GRDB. Why:
five streams edit Package.swift tonight; GRDB is a remote dependency that needs network resolution, a Package.resolved,
an App-bundled notice (App/ThirdPartyNotices.txt belongs to stream D) and a CI cache. The store sits behind one
queue-confined type, so moving to GRDB later changes one file. Migrations are explicit (`PRAGMA user_version`).

## Tasks

1. **ImportInbox gates.** `ImportedFile.contentID` (stable identity: SHA-256 of STREAMINFO + first 64 KiB of audio
   frames, so renames, moves and tag edits keep it). Source reads under `NSFileCoordinator` (iCloud fetches first).
   `maxFileBytes` bound (8 GiB default, spec §5.8). All file I/O on a private serial `DispatchQueue`, never the
   cooperative pool; the queue also keeps imports and listings from interleaving. `list()` keeps an index keyed by
   name + size + mtime and re-parses only new or changed files.
   Tests: content ID survives rename and tag-block edits; size bound rejects; list() does not re-parse (parse counter).
2. **PFCore models + album grouping.** Album key: album artist (else artist) + album, folded; untagged album falls back
   to the folder, so an untagged rip stays one album. Best format = max bits, then rate. Track order: disc, number,
   title. Tests: grouping, compilations by ALBUMARTIST, untagged, ordering, best format.
3. **LibraryDatabase + LibraryScanner.** Tables `folders`, `tracks` (folder-relative path: iOS container paths move on
   update), `artwork`, `skipped` (rejected or duplicate files with size + mtime, so a rescan never re-reads them).
   Scan: enumerate (name, size, mtime) cheaply; parse only new/changed; match a missing path's content ID → move
   (keeps the ID); delete what is gone. Hidden names and non-`.flac` never admitted; every file passes `FlacValidator`
   via `FlacMetadataReader`. iCloud placeholders are reported as pending and their download is started.
   Tests: hostile tags (huge, empty keys, bad UTF-8, non-ASCII), rescan touches only changed files, deletion, move,
   duplicate, rejected file not re-read, reopen database.
4. **ArtworkStore.** Front cover extracted once per distinct image (content hash), downsampled with ImageIO to 600 px
   JPEG; refuses images over 16 MiB or 64 Mpx. Byte-bounded `NSCache` for decoded data. Tests: dedup, bound, missing.
5. **Library facade.** `final class Library: Sendable`; every operation on one serial utility queue; publishes
   `LibraryCatalog` through `current` (lock-protected) and `changes()`. `importFiles` = ImportInbox → incremental scan
   of the library folder. `addFolder(url)` stores a bookmark, keeps the folder's security scope for the app's life.
6. **SearchIndex.** Fold (NFD, diacritics, case, width), split on whitespace, drop punctuation (`AC/DC` → `acdc` plus
   `ac`, `dc`). Sorted flat vocabulary (UInt32 scalars) + postings (doc, field). Per query token: exact word, prefix
   range by binary search, one-edit typo (incl. transposition) for tokens ≥ 4 over the vocabulary with a bounded
   check. AND across tokens. Score: no-typo tier > exact whole title > title prefix > Σ quality × field weight >
   album kind > shorter title. Top-k selection, no full sort. Highlights computed only for returned hits.
   Filters: all, albums, songs, 24-bit+, 32-bit, ≥96 kHz. `suggest(_:limit:)` synchronous for stream E.
   Tests: golden ranking, accents, punctuation, typos, filters, highlights, incremental rebuild.
7. **Benchmark.** Synthetic 10k-track catalog; 200 realistic keystroke prefixes; p95 < 8 ms × `LatencyBudget`.
8. **M5 gate.** `trackStarted` carries the decoder's total frames; Player updates `totalFrames` with `format`.

## Interfaces (for the controller's adapter)

```swift
let library = try Library(databaseURL:, libraryFolder:, artworkFolder:)
library.current: LibraryCatalog; library.changes() -> AsyncStream<LibraryCatalog>
await library.importFiles(urls) -> LibraryImportResult; await library.rescan(); await library.addFolder(url)
let snapshot = LibrarySnapshot(catalog)            // build off the main actor
snapshot.albums; snapshot.tracks(of:); snapshot.tracks(ids:); snapshot.search(q, filter:, limit:); snapshot.suggest(p, limit:)
library.artwork(for: album.artworkID) -> Data?;   QueueItem(track:, artwork:)
```

## Out of scope tonight

Play history and Up Next tables, loudness, sidecar `cover.jpg`, file watching (rescan on launch/foreground instead),
the opt-in MusicBrainz artwork lookup, the 100k-track budget (measured, not gated), Verify-album.
