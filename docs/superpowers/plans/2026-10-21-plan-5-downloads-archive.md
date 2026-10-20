# pointFlac Plan 5: Downloads and the Internet Archive provider

**Goal:** A download pipeline that can only ever hand the library real FLAC, and an Internet Archive provider that only
offers open-licence FLAC files, both host-tested without the network.

**Spec:** §4.7 (Internet Archive, Downloads list), §5.1 (`PFDownloads`, `PFArchive`), §5.3, §5.4 (staging and
publication), §5.8. Contract 1 in the overnight `common.md` fixes the provider protocol.

**Architecture:**
- `PFDownloads` (depends on `PFCore`, `PFFlac`): contract-1 types, `SafeFileName`, `DownloadManager` actor,
  `DownloadQueueStore` (JSON), `DownloadsObserver` (`@MainActor @Observable` mirror for the UI).
- `PFArchive` (depends on `PFDownloads`): `ArchiveProvider: DownloadProvider`, `ArchiveClient` (rate-limited, size-capped
  JSON over HTTPS), `ArchiveLicence`, `ArchiveFileSelector`, `ArchiveQuery`.
- The spec table puts the provider protocol in `PFDownloads`, so `PFArchive → PFDownloads` is the one feature-to-feature
  edge. Soulseek (stream C) gets a thin adapter at integration instead.

## Tasks

### 1. Package targets
`PFDownloads`, `PFArchive`, `PFDownloadsTests`, `PFArchiveTests` in `Package.swift`. Tests depend on `PFTestSupport` for
the FLAC fixtures.

### 2. Contract types (`PFDownloads/DownloadProvider.swift`)
`RemoteTrack`, `DownloadEvent`, `DownloadProvider` exactly as contract 1. `RemoteTrack` also gets `Codable` (additive)
so the queue can be persisted.

### 3. `SafeFileName`
`sanitize(_ remote: String) -> String?`: last component of `/` or `\` paths, NFC, no control characters, `:`, leading
dots or trailing spaces, at most 200 UTF-8 bytes with the extension kept, must end in `.flac` (else `nil`).
Tests: traversal (`../../x.flac`, `..\\x.flac`), empty, `.flac` only, unicode, overlong, non-FLAC.

### 4. `DownloadManager` actor
- `enqueue(_:) -> DownloadItem.ID`, `cancel(_:)`, `retry(_:)`, `remove(_:)`, `items`, `updates() -> AsyncStream<[DownloadItem]>`.
- States `queued → downloading(progress) → validating → saving → published(URL)`, or `failed(String)`, `cancelled`.
- At most `maxConcurrent` (2) jobs run. Each job gets a private `0700` staging folder under `stagingRoot/<job id>/`.
- Before downloading: size limit (`maxFileBytes`, default 2 GiB) and free disk space (`2 × size + 256 MiB` margin).
- Provider stream errors retry with exponential backoff (`maxAttempts` 3); the staged `.part` lets a provider resume.
  A `.failed` event is final.
- On `.finished(url)`: the URL must be a regular file inside the job's staging folder (symlinks refused), within the
  size limit and equal to `sizeBytes` when known. It is renamed to the sanitised name, `0600`, then `FlacValidator`
  must accept it before `publish` is called. Nothing else ever opens it.
- `publish` failure keeps the validated file so `retry` republishes without downloading again.
- Cancelling deletes only the staging folder; `saving` and `published` jobs cannot be cancelled, so published music
  is never touched.
- `DownloadQueueStore` writes the queue atomically after every state change. On launch, unfinished jobs return to
  `queued` (and resume); finished, failed and cancelled ones stay as history.
Tests (fake provider, temp dirs, zero backoff): happy path publishes a fixture; renamed MP3 / bad CRC rejected and never
published; path escape and symlink refused; oversize and size mismatch; disk full; concurrency never exceeds 2; retry
after a thrown error; cancel mid-download; publish failure then retry; persistence round trip and resume.

### 5. `ArchiveClient`
`URLSession`-backed, descriptive User-Agent `pointFlac/0.2 (+https://github.com/kiraa06/pointFlac)`, HTTPS only,
minimum interval between requests (default 250 ms), `429`/`503` honour `Retry-After` up to a cap, JSON bodies capped
(scrape 4 MiB, metadata 8 MiB). Errors: `offline`, `notFound`, `http(Int)`, `tooLarge`, `badResponse`.

### 6. Search and selection
- `ArchiveQuery.build(userQuery)`: splits the text into plain words (everything but letters, digits, marks and
  `-'._` separates), quotes each, then
  `("w1" "w2") AND mediatype:audio AND format:(Flac OR "24bit Flac") AND (licenseurl:*creativecommons.org* OR collection:etree)`.
  Backslash escaping was tried first; the Archive's backend errors on `\-` and on `/` even inside quotes.
- **Deviation from §4.7:** advanced search (`/advancedsearch.php`, `sort[]=downloads desc`, `rows=50`) instead of the
  scrape API. On 2026-10-21 the scrape API answered a new `q` with the cached result of an earlier query whenever the
  other parameters matched (reproduced with curl). Advanced search's 10,000-result ceiling does not matter for a
  first page. First `maxItems` (20) identifiers get a metadata request.
- Metadata API per item (`/metadata/<id>`), one batch yielded per item as it arrives. `{}` means missing.
- `ArchiveLicence.classify(licenseurl, collections)`: CC licences and public-domain marks, or `etree`; anything else,
  including no licence, hides the item. The client re-checks; the query filter is only a hint.
- `ArchiveFileSelector`: format `Flac`/`24bit Flac`, `source == "original"`, name ends `.flac`, safe path, size > 0.
  `24bit Flac` → `bitsPerSample = 24`; plain `Flac` stays `nil` (Archive does not say).
- `RemoteTrack.id = "archive:<identifier>/<path>"`; `detail` keeps `identifier`, `path`, `licence`, `licenceURL`, `md5`.
Tests: recorded fixtures (trimmed real responses), query escaping, licence table, file selection, missing item.

### 7. Download
`https://archive.org/download/<id>/<path>` with per-segment percent-encoding, into `<staging>/<sanitised>.part`.
Range resume from an existing `.part` (206 appends, 200 restarts). Size cap = listed size; truncated or oversized
bodies fail; MD5 must match the listing; then rename to the final name and emit `.finished`.
Tests: progress events, resume sends `Range`, 200-on-resume restarts, 404, offline, truncated, MD5 mismatch, a non-FLAC
payload passes the provider and is refused by the manager.

### 8. Live test (opt-in, `PF_LIVE_TESTS=1`)
Searches the real Archive for `dusty-sense` (CC0, 3.5 MB 24-bit FLAC) and runs it through `DownloadManager` into a temp
library. Run once, result recorded in the report.

### 9. Friday Drops
`FridayDrops` actor: a pool of up to 300 CC-licensed `collection:netlabels` FLAC releases, ordered by a SplitMix64
Fisher-Yates shuffle seeded by the UTC ISO week (pool sorted first, so the Archive's ordering does not matter),
then confirmed one by one against the metadata API until ten albums with selectable FLAC are found (at most 25
checks). The first shelf of a week is saved as JSON and reused for that week; offline at the start of a week, the
last shelf is kept. No claim limit. Runout's exact selection code was not available, so this is a week-seeded
pick in Runout's spirit, not a port.
Tests: UTC/ISO week boundaries, order independence and a pinned order, shelf of ten skipping empty items,
snapshot reuse without network, new-week refresh, offline fallback.

## Not in this plan
Background `URLSession` (needs the app delegate; integration work), pause, MD5 "Verify album" badges, the UI.
