# pointFlac Plan 8: Smart-search middleware (`PFFind`)

> Overnight stream E. Time box: commit by 06:45 IST. Host tests only; the network is stubbed with `URLProtocol`
> except one opt-in live test (`PF_LIVE_TESTS=1`).

**Goal:** bridge the gap between what a person types ("the mountain gorillaz") and the literal words that appear in
strangers' Soulseek folder names, without making typing feel slow. Live evidence from 2026-10-21: the Soulseek query
"The Mountain Gorillaz" returned 0 results while "The Mountain" returned 304 peers and 3,556 FLAC files, Gorillaz's
album among them.

**Architecture:** one new target, `PFFind`, depending on Foundation (and CryptoKit for cache keys) only. It never
imports stream A's or B's types: the library is an injected closure, Soulseek results arrive as `CandidateFile`.

```
keystroke ─▶ TypeaheadEngine ─▶ 1. library closure (same call, synchronous)        ─▶ emit
                              ├▶ 2. suggestion LRU (exact or longest cached prefix) ─▶ emit
                              └▶ 3. debounce 250 ms ─▶ MusicBrainzRegistry ─▶ emit per entity request
                                        │                 └▶ MusicBrainzClient: memory LRU ▸ disk TTL cache ▸ token
                                        │                    bucket (1 req/s, GCRA) ▸ URLSession (cancellable)
pick ─▶ resolve(Suggestion) ─▶ ResolvedEntity (+ MusicBrainz track count)
     ─▶ SoulseekQueryPlanner.plan(entity, excludedPhrases) ─▶ [QueryVariant] (run sequentially by the caller)
     ─▶ ResultRanker.rankAlbums(files, entity, preference) ─▶ [AlbumCandidate] with a "why" string
     ─▶ ArchiveQueryBuilder.queries(entity) ─▶ [String] for stream B's provider
```

## Task 1: Text normalisation and fuzzy scoring (`FindText`, `FuzzyMatcher`)
- `FindText.fold`: NFD, strip combining marks, case-fold, `ø→o`, `ß→ss`, `&`→`and`, punctuation → space, collapse.
- `FindText.tokens`, stopwords, `withoutLeadingArticle`, `withoutFeaturing` ("feat.", "ft.", "featuring", "with"),
  `withoutParentheticals` ("(Remastered 2011)", "[Deluxe]", " - 2011 Remaster").
- `FuzzyMatcher.score(query:candidate:) -> Double` in 0…1: per query token best candidate token: exact 1.0, prefix
  0.9 (last token is being typed), one edit (OSA distance; two for ≥ 8 letters) 0.75, substring 0.6; weighted by token
  length; a bonus for covering the whole candidate and for in-order matches.
- Tests: diacritics (Björk/bjork), "The" prefix, `&`/and, feat. variants, one-letter typos, transpositions.

## Task 2: Rate limiter and cache
- `TokenBucket` actor (GCRA): `acquire()` reserves the next slot and sleeps until it; cancellation returns the slot.
  `penalize(retryAfter:)` pushes the next slot out after a 503/429.
- `LRUCache<Key, Value>` (Mutex-guarded, Sendable) and `DiskCache` (one file per SHA-256 key, TTL, `allowStale` for
  offline use, entry cap with oldest-first pruning).
- Tests: spacing ≥ interval, burst capacity, cancellation frees the slot, LRU eviction order, TTL expiry, stale reads.

## Task 3: MusicBrainz client and registry
- `MusicBrainzClient`: `search(_ entity: MBEntity, query: String, limit: Int)` and `releases(ofReleaseGroup:)`.
  User-Agent `pointFlac/0.2 ( https://github.com/kiraa06/pointFlac )`, JSON only, 2 MB response cap, one retry
  after 503 with back-off, stale cache when offline.
- `MusicBrainzQuery`: Lucene builder. Escapes specials; last token `tok*` while typing; `tok~1` for ≥ 5 letters;
  **field splits**: every split of the tokens into (title part, artist part), both orders, plus whole-title and
  whole-artist clauses. Recorded evidence: this one request turns "the mountain gorillaz" into exactly *The Mountain*
  by Gorillaz, and "radiohed ok computer" into *OK Computer* by Radiohead.
- `MusicBrainzRegistry`: maps artists, release groups and recordings to `Suggestion`s with a `ResolvedEntity`;
  request order album → artist → track (one per second), each emitted as it lands; suggestion-level LRU.
- Tests: recorded fixtures via `StubURLProtocol`, User-Agent header, rate spacing across calls, cancellation of an
  in-flight request, cache hit makes no request, 503 retry, offline stale fallback.

## Task 4: Typeahead engine
- `TypeaheadEngine.suggestions(_ partial:) -> AsyncStream<[Suggestion]>`; a newer call cancels the older stream.
- Merge: dedupe on (kind, folded title, folded artist), library wins; rank by fuzzy score, kind and source weight,
  MusicBrainz score as tie-break.
- Tests: ordering (library first, then cached, then live), debounce cancels superseded keystrokes, dedupe, ranking
  ("the mountain gorillaz" puts the album first), benchmark: first emission < 16 ms over a 10k-item library closure.

## Task 5: Soulseek query planner
- `SoulseekQueryPlanner.plan(for:excludedPhrases:maxVariants:) -> SearchPlan` (ordered `QueryVariant`s: query,
  intent, `requiresArtistFilter`). Album title first when distinctive, then artist + distinctive album words, then
  folded-diacritic and stopword-free forms; generic titles ("Greatest Hits", "Live") lead with the artist.
- Never emits a variant containing an excluded phrase. If the entity's own artist, album or track name contains an
  excluded phrase, the plan is empty and says why (spec §5.6: honour the server's excluded-phrases list).
- Tests: "Gorillaz – The Mountain" → `["the mountain", "gorillaz mountain", …]`, feat./parentheticals/numbers,
  diacritics, excluded phrases, dedupe, the variant cap.

## Task 6: Result ranker and grouper
- `ResultRanker.rankAlbums(_ files: [CandidateFile], for: ResolvedEntity, preference:) -> [AlbumCandidate]`: FLAC
  only; group by peer and folder (CD1/Disc 2 subfolders fold into the album); completeness against the MusicBrainz
  track count; score = match, completeness, format (preference, default highest), availability (free slot, speed,
  queue). `why`: "Complete album · 24/96 · free slot".
- `rankTracks` for track entities. Paths with excluded phrases are dropped when the list is given.
- Tests: synthetic and realistic backslash paths, multi-disc, wrong-artist folders filtered, preference ordering.

## Task 7: Internet Archive query strings
- `ArchiveQueryBuilder.queries(for:)` → ordered advancedsearch/scrape `q` strings (creator + title + FLAC formats,
  then title-only), quoted and escaped. Stream B owns the provider.

## Task 8: Integration helpers (added during the night)
- `SearchPlanRunner`: runs a plan variant by variant through a process-wide Soulseek token bucket (5 s), re-ranks
  after every batch, stops at enough complete albums.
- `CoverArtArchive`: lazy, cached (hits and misses, 30 days) thumbnails, opt-in, size-capped.
- `SmartSearch`: one-per-process facade (one MusicBrainz client, so one cache and one limiter) for the
  `MusicFinding` adapter. Default buckets are statics, so a second client still shares one request per second.

## Task 9: Opt-in live test, lint, report
- `PF_LIVE_TESTS=1 swift test --filter PFFindLiveTests` once; `swift format lint --strict`; full `swift test`.
