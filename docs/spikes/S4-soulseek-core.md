# S4: Soulseek core choice

**Date:** 2026-10-21 (overnight build, stream C). **Decision:** write a focused native Swift client in `PFSoulseek`.
SeeleseekCore stays reading material (it is MIT, so borrowing ideas is fine; no code was copied).

## SeeleseekCore evaluation (time-boxed to 20 minutes)

Checked `github.com/bretth18/seeleseek` at commit `195eddc` (2026-10-12), `Packages/SeeleseekCore`.

| Criterion | Finding |
|---|---|
| Licence | MIT (Brett Henderson). Acceptable under §3.3. |
| Maturity | Active (commits on 2026-10-12), about 21,300 lines across 40 files. Its protocol tests live in the app's test target (about 15,000 lines), not in the package; the package's own test target only tests the MMDB reader. |
| Login, search, download | All present, plus obfuscation, NAT-PMP/UPnP, distributed network, uploads, sharing, GeoIP, chat rooms. |
| Swift 6 | Swift 6.2 tools with `NonisolatedNonsendingByDefault`; actors throughout, with `@MainActor` collaborators. Builds with our Swift 6.3 toolchain. |

Why it was not adopted tonight:

1. **It cannot be consumed as a package.** Its `Package.swift` lives in a subdirectory of an app repository, and
   SwiftPM only resolves packages at a repository root. Using it means vendoring all 21,000 lines.
2. **Sharing is woven through the core.** `NetworkClient` owns a `ShareManager` and an `UploadManager` (2,290 lines),
   reads `UserDefaults` for NAT settings, runs UPnP/NAT-PMP and GeoIP lookups and calls a `@MainActor` activity logger.
   §2 and §5.6 require no sharing and no uploads; extracting them is a large, risky edit to code we did not write.
3. **Its limits are far above §5.6's hardening list.** Peer frames are capped at 100 MB with a 150 MB receive buffer,
   server buffers at 50 MB, and zlib inflate at 256 MiB with a 1000:1 ratio check. §5.6 asks for small control-frame
   caps and 16 MiB / 32 MiB inflate caps. Every one of those would need patching in a vendored fork.
4. **The traffic we need is narrow.** Tonight's live probe showed that behind NAT every search result arrives through
   server `ConnectToPeer` (18) answered with `PierceFireWall`. A small client built around exactly that flow (capped,
   time-limited parallel connects) is easier to harden, test and review than a general-purpose client.

The Rust fallback (soulseek-rs) was not needed: a Swift-native client avoids the UniFFI bridge and the second toolchain.

## What the native client covers

See `docs/superpowers/plans/2026-10-21-plan-6-soulseek.md`. Login (with the error states), keepalive, reconnect,
rate-limited search over indirect connections, excluded search phrases, and FLAC downloads through indirect `F`
connections with resume by offset. Everything is tested against a local mock server and mock peers.

## Protocol facts verified live (probe as the user's test account, 2026-10-21)

- `server.slsknet.org:2242`; Login = username, password, version u32, md5(username + password) hex, minor u32.
  Version 160 / minor 1 logs in.
- Search is literal word matching: "The Mountain Gorillaz" → 0 results; "The Mountain" → 304 peers, 17,761 files,
  3,556 FLAC in 30 s.
- Behind NAT no inbound peer connection arrives. About 23,000 `ConnectToPeer` (type P) messages arrive in 30 s; each is
  answered by connecting out and sending `PierceFireWall` (u32 len 5, u8 0, u32 token); results then arrive as a
  zlib-compressed `FileSearchResponse` (peer code 9).
- The server sends `ExcludedSearchPhrases` (160) after login.

## Open items

- §5.6 says pointFlac should use the experimental major version 177 in development and ask the Soulseek admins for its
  own number before wider release. The client's version is configurable; see the stream report for which default was
  verified live.
- Peers may refuse uploads to users who share nothing (§10 risk); the UI must explain this (§4.7).
