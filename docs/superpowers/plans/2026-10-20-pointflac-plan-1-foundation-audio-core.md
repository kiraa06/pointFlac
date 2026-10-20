# pointFlac Plan 1: Foundation & Audio Core — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A thin pointFlac app that imports FLAC files (16-, 24- and 32-bit) from Files, rejects anything that isn't real FLAC, and plays them gaplessly through iOS. The bytes it hands to iOS must be proven bit-exact, and an honest signal readout must say what is happening.

**Architecture:**
- An XcodeGen-generated iOS app sits on top of one local Swift package, `PointFlacKit`, with one target per responsibility:
  - `PFCore`: pure models and the signal and format policy
  - `CFLAC`: libFLAC 1.5.0, vendored as a C target
  - `PFFlac`: validation, metadata and decoding
  - `PFDSP`: dither and resampling
  - `PFAudio`: ring buffer, pipeline, session and RemoteIO output, and the `Player` facade
  - `PFLibrary`: import inbox
- The decoding thread fills a lock-free ring buffer. A real-time-safe render callback drains it into RemoteIO. The client sample rate always equals the hardware rate, so iOS never resamples silently.
- Everything except the RemoteIO and session code is host-testable with `swift test`.

**Tech Stack:**
- Swift 6.3 (language mode 6, complete strict concurrency), SwiftUI, AudioToolbox RemoteIO, AVFAudio (session and AVAudioConverter), MediaPlayer (Now Playing)
- `Synchronization.Atomic`, Swift Testing, XCTest (UI and performance)
- libFLAC 1.5.0 (BSD-3), XcodeGen 2.46.0, swift-format 6.3
- ffmpeg and lame (fixture generation only, never shipped)

**Spec:** `docs/superpowers/specs/2026-10-20-pointflac-design.md`. Read §3.2, §5.1–§5.3, §5.7, §6 and §8 before starting.

**This is plan 1 of 7.** Later plans, each with its own document:
- 2 · Library & search
- 3 · Player UI (Deck, Cover, Shelf, hand-off animation)
- 4 · Sound section (DSP)
- 5 · Internet Archive
- 6 · Soulseek module
- 7 · Release, CI hardening & README

## Prerequisites (before Task 1)

- Xcode 26.6 with its licence accepted (done). Simulator runtime iOS 26.5, being downloaded via `xcodebuild -downloadPlatform iOS`.
- **Needs Kiran's go-ahead:** `brew install xcodegen` (2.46.0, MIT).
- **Needs Kiran's go-ahead:** download the libFLAC 1.5.0 source from `https://github.com/xiph/flac/releases/download/1.5.0/flac-1.5.0.tar.xz` (Task 3).
- **Device steps only** (Tasks 11, 12 and 14, device sections): Kiran's iPhone 17 Pro runs iOS 27.2 beta, so it needs the Xcode beta that supports iOS 27.2, which may need a newer macOS than 26.4. Until then, every task verifies on the simulator, and device checks are recorded as pending.

## Global Constraints

- iOS deployment target **26.0**; host test platform macOS 26.0. Swift language mode 6, `SWIFT_STRICT_CONCURRENCY = complete`.
- Bundle ID **`io.github.kiraa06.pointflac`**; display name **`pointFlac`**; app target and scheme `PointFlac`.
- MIT licence. Only MIT, BSD, zlib, Apache-2.0 or public-domain code may be linked. No GPL, LGPL or AGPL code. The ffmpeg and lame tools only *generate fixtures* and are never linked or shipped.
- Music is FLAC only. No analytics, crash or tracking SDKs. No network access in this plan.
- libFLAC **1.5.0** for every FLAC decode; never Apple's FLAC decoder, which fails on 32-bit.
- **Client sample rate always equals the hardware sample rate.** iOS must never resample silently; pointFlac resamples itself and says so.
- The word "bit-perfect" never appears in the UI in v1. The strongest claim is "● Pure" or "Untouched by pointFlac".
- Performance budgets:
  - Play or needle drop → first rendered sample: **< 150 ms** for local files.
  - Seek → audio at the new position: **< 50 ms**.
- The render thread is real-time safe. It never allocates, takes a lock, logs, calls Objective-C or Swift-runtime APIs that may lock, or causes ARC retain/release traffic.
- **Commits:**
  - Conventional Commits (`feat(flac): …`).
  - Author `Kiran P Jose <kiran.p.jose02@gmail.com>`, set repo-locally in Task 1.
  - Every **push** needs Kiran's explicit go-ahead at that time.
  - Local commits follow the working agreement confirmed when execution starts.
- Formatting: `swift format lint --strict` must pass using the repo's `.swift-format` file (4-space indent, line length 120).

## Review Focus

These are the conditions the spec implies but no feature test would naturally hit. Each has a pinned test in its owning task.

1. **The file becomes unreadable mid-playback** (deleted, moved, iCloud-evicted): that track stops cleanly with an error event and the next queued item plays. No crash, no garbage audio. → Task 10, `decoderFailureSkipsToNextItem`.
2. **Headphones or DAC unplugged mid-song, or a phone call:** playback pauses. After an interruption it resumes only when iOS says it should. → Task 13, `pausesWhenOutputUnplugged`, `resumesAfterInterruptionOnlyWhenAllowed`.
3. **Rapid repeated seeks** (scrubbing a slider): the last seek wins, and audio continues from exactly that frame with no stale buffers. → Task 10, `seekSpamLatestWins`.
4. **A damaged frame in the middle of a file:** playback continues through it, with that block output as silence, and no failure event. → Task 6, `reportsMidstreamDamageAndContinues`; Task 10, `midstreamDamagePlaysThrough`.
5. **Consecutive tracks with different sample rates or bit depths** (44.1/16 then 96/24): both play bit-exactly, with a reconfiguration at the boundary and no garbled samples. → Task 10, `formatChangeBetweenTracksReconfigures`.

---

## File structure (created by this plan)

```
.gitignore  .swift-format  LICENSE  README.md  project.yml
scripts/bootstrap.sh  scripts/test.sh  scripts/make-fixtures.py
.github/workflows/ci.yml
docs/spikes/S1-output-path.md  docs/spikes/S2-libflac.md  docs/spikes/S3-rate-negotiation.md
docs/third-party.md
App/
  PointFlacApp.swift            app entry, owns AppModel
  AppModel.swift                composition root: Player, ImportInbox
  Debug/DebugLibraryView.swift  import + list (temporary; replaced in Plan 3)
  Debug/DebugNowPlayingView.swift  transport + signal strip (temporary)
  Debug/Fixtures/               DEBUG-only copies of 3 fixtures for UI tests
  Assets.xcassets
AppUITests/PlaybackSmokeTests.swift
Packages/PointFlacKit/
  Package.swift
  Sources/PFCore/      AudioFormat.swift  OutputPort.swift  OutputPlan.swift  SignalState.swift  SignalStrip.swift
  Sources/CFLAC/       (vendored libFLAC 1.5.0) include/CFLAC.h  config.h
  Sources/PFFlac/      FlacStreamInfo.swift  FlacValidator.swift  FlacMetadata.swift  FlacDecoder.swift  FlacIntegrity.swift
  Sources/PFDSP/       TPDFDither.swift  SampleRateConverter.swift
  Sources/PFAudio/     SampleRing.swift  PCMDecoding.swift  RenderSource.swift  PlaybackPipeline.swift
                       AudioOutput.swift  AudioSessionControlling.swift
                       iOS/SystemAudioSession.swift  iOS/RemoteIOOutput.swift  iOS/SystemNowPlaying.swift
                       Player.swift  QueueItem.swift  NowPlayingPublishing.swift
  Sources/PFLibrary/   ImportInbox.swift
  Sources/PFTestSupport/  Fixture.swift  FakeOutput.swift  FakeSession.swift  Resources/Fixtures/*.flac|*.raw|manifest.json
  Tests/PFCoreTests/  PFFlacTests/  PFDSPTests/  PFAudioTests/  PFLibraryTests/  CFLACTests/
```

---

### Task 1: Repository and project scaffold

**Files:**
- Create: `.gitignore`, `.swift-format`, `LICENSE`, `README.md`, `project.yml`, `scripts/bootstrap.sh`, `scripts/test.sh`, `App/PointFlacApp.swift`, `App/Assets.xcassets`, `Packages/PointFlacKit/Package.swift`, `Packages/PointFlacKit/Sources/PFCore/AudioFormat.swift`
- Test: `Packages/PointFlacKit/Tests/PFCoreTests/AudioFormatTests.swift`

**Interfaces:**
- Produces:
  - `public struct AudioFormat: Sendable, Hashable, Codable { public var sampleRate: Int; public var bitsPerSample: Int; public var channels: Int; public init(sampleRate:bitsPerSample:channels:) }`
  - `var formattedRate: String`: "44.1 kHz", "96 kHz", "352.8 kHz"
  - `var formattedDepth: String`: "24-bit"

- [ ] **Step 1: Initialise git in `~/Documents/Echocore` and set the identity repo-locally**

```bash
cd ~/Documents/Echocore && git init -b main
git config user.name "Kiran P Jose" && git config user.email kiran.p.jose02@gmail.com
```

- [ ] **Step 2: Add the ignore, licence and format files**
  - `.gitignore` covers `.superpowers/`, `*.xcodeproj` (it is generated), `.build/`, `DerivedData/`, `xcuserdata/`, `.swiftpm/`, `*.ipa` and `.DS_Store`.
  - `LICENSE` is MIT, "Copyright (c) 2026 Kiran P Jose".
  - `.swift-format` sets `indentation.spaces: 4` and `lineLength: 120`.

- [ ] **Step 3: Write `Package.swift`**
  - `swift-tools-version: 6.0`, platforms `.iOS("26.0"), .macOS("26.0")`.
  - Library products `PFCore`, `PFFlac`, `PFDSP`, `PFAudio`, `PFLibrary`.
  - Targets per the file structure. `PFTestSupport` has `resources: [.copy("Resources/Fixtures")]`. Every test target depends on `PFTestSupport`.
  - `swiftSettings: [.swiftLanguageMode(.v6)]` on every Swift target.
  - Tasks 2–13 fill in targets other than `PFCore` as they arrive. Declare only `PFCore` and `PFCoreTests` now.

- [ ] **Step 4: Write the failing test `AudioFormatTests`**

```swift
@Test func formatsRatesAndDepths() {
    #expect(AudioFormat(sampleRate: 44_100, bitsPerSample: 16, channels: 2).formattedRate == "44.1 kHz")
    #expect(AudioFormat(sampleRate: 96_000, bitsPerSample: 24, channels: 2).formattedRate == "96 kHz")
    #expect(AudioFormat(sampleRate: 352_800, bitsPerSample: 32, channels: 2).formattedRate == "352.8 kHz")
    #expect(AudioFormat(sampleRate: 48_000, bitsPerSample: 32, channels: 2).formattedDepth == "32-bit")
}
```

- [ ] **Step 5:** Run `swift test --package-path Packages/PointFlacKit`. Expected: FAIL, `AudioFormat` not found.

- [ ] **Step 6: Implement `AudioFormat` in `PFCore/AudioFormat.swift`**
  - The rate formats as kHz with one decimal place only when the rate isn't a whole number of kHz.
  - The `en_US_POSIX` locale is always used.

- [ ] **Step 7:** Run the same command. Expected: PASS.

- [ ] **Step 8: Write `project.yml`**
  - `name: PointFlac`, `options.deploymentTarget.iOS: "26.0"`, `packages.PointFlacKit.path: Packages/PointFlacKit`.
  - Base settings: `SWIFT_VERSION: "6.0"`, `SWIFT_STRICT_CONCURRENCY: complete`, `MARKETING_VERSION: 0.1.0`, `CURRENT_PROJECT_VERSION: 1`.
  - Target `PointFlac`: an iOS application with `sources: [App]` and dependency on the `PFCore` package product.
    - `PRODUCT_BUNDLE_IDENTIFIER: io.github.kiraa06.pointflac`.
    - Info properties: `CFBundleDisplayName: pointFlac`, `UIBackgroundModes: [audio]`, `UIFileSharingEnabled: true`, `LSSupportsOpeningDocumentsInPlace: true`, `UILaunchScreen: {}`.
  - Target `PointFlacUITests`: `bundle.ui-testing`.
  - Scheme `PointFlac` that tests `PointFlacUITests`.

- [ ] **Step 9: Write `scripts/bootstrap.sh` and `scripts/test.sh`, and a minimal app**
  - `scripts/bootstrap.sh` runs `xcodegen generate`.
  - `scripts/test.sh` runs, in order, failing fast:
    1. `swift format lint --strict --recursive App Packages`
    2. `swift test --package-path Packages/PointFlacKit`
    3. `xcodebuild test` of the package scheme `PointFlacKit-Package` on `platform=iOS Simulator,name=iPhone 17 Pro`
    4. `xcodebuild test -scheme PointFlac` on the same simulator
  - Minimal `App/PointFlacApp.swift`: a window with `Text("pointFlac")`.
  - `README.md`: a one-paragraph description of pointFlac plus "Build: `scripts/bootstrap.sh && open PointFlac.xcodeproj`".

- [ ] **Step 10:** Run `scripts/bootstrap.sh && xcodebuild build -scheme PointFlac -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`. Expected: `** BUILD SUCCEEDED **`. If that simulator name doesn't exist, use the closest iPhone Pro listed by `xcrun simctl list devices` and update `scripts/test.sh`.

- [ ] **Step 11: Commit**

```bash
git add -A && git commit -m "chore: scaffold pointFlac app, PointFlacKit package and tooling"
```

---

### Task 2: Test fixtures

**Files:**
- Create: `scripts/make-fixtures.py`, `Packages/PointFlacKit/Sources/PFTestSupport/Fixture.swift`, `Packages/PointFlacKit/Sources/PFTestSupport/Resources/Fixtures/*`
- Modify: `Package.swift` (add the `PFTestSupport` target with fixture resources; `PFCoreTests` depends on it)
- Test: `Packages/PointFlacKit/Tests/PFCoreTests/FixtureManifestTests.swift`

**Interfaces:**
- Produces:
  - `public struct Fixture: Sendable, Decodable { name, file: String, raw: String?, sampleRate, bits, channels: Int, frames: Int64, expect: Expectation, rejection: String?, hasMD5: Bool, multichannel: Bool }`
  - `enum Expectation: String { case accept, reject }`
  - `public enum Fixtures { static let all: [Fixture]; static func url(_ f: Fixture) -> URL; static func rawSamples(_ f: Fixture) -> [Int32]; static func named(_ name: String) -> Fixture }`

**The `.raw` format:** interleaved Int32 little-endian, in **native range** (−2^(b−1)…2^(b−1)−1).

**Signal (deterministic):**
- **Left channel:** 32-bit LCG noise (`x = x &* 1664525 &+ 1013904223`, seed 0x5EED), arithmetic-shifted right by `32 − b`.
- **Right channel:** a bit walk. Sample n is `(1 << (n % (b − 1)))`, negated on odd n.
- **Mono:** left only. **6-channel:** channel c uses seed `0x5EED + c`.

**Fixtures** (4096 frames each unless noted):

| name | rate | bits | ch | expect | notes |
|---|---|---|---|---|---|
| s16-44100 | 44 100 | 16 | 2 | accept | |
| s16-48000 | 48 000 | 16 | 2 | accept | |
| s16-44100-mono | 44 100 | 16 | 1 | accept | |
| s24-44100, s24-48000, s24-88200, s24-96000, s24-176400, s24-192000, s24-384000 | as named | 24 | 2 | accept | |
| s32-44100, s32-48000, s32-96000, s32-192000 | as named | 32 | 2 | accept | encode with `-strict experimental` |
| s16-48000-6ch | 48 000 | 16 | 6 | accept | `multichannel: true` |
| id3-s24-48000 | 48 000 | 24 | 2 | accept | prepend a valid 64-byte ID3v2.4 tag |
| nomd5-s16-44100 | 44 100 | 16 | 2 | accept | STREAMINFO MD5 zeroed; `hasMD5: false` |
| corrupt-mid-s16-44100 | 44 100 | 16 | 2 | accept | 16384 frames, block size 4096; flip one payload byte in frame 3 (frames 8192–12287) |
| renamed-mp3 | — | — | — | reject `badMagic` | 1 s lame MP3 saved as `.flac` |
| truncated-meta | 44 100 | 16 | 2 | reject `truncated` | `s16-44100` cut right after the last metadata block |
| bad-streaminfo | 44 100 | 16 | 2 | reject `invalidStreamInfo` | min block size set to 0 |
| bad-frame-crc | 44 100 | 16 | 2 | reject `frameCRCMismatch` | flip one bit in the first frame header's CRC-8 |
| empty | — | — | — | reject `truncated` | 0 bytes, named `empty.flac` |
| not-flac-name | 44 100 | 16 | 2 | reject `notFlacName` | valid FLAC bytes named `not-flac-name.wav` |

- [ ] **Step 1: Write the failing test**

```swift
@Test func manifestLoadsAndRawMatchesFrames() throws {
    #expect(Fixtures.all.count == 24)
    let f = Fixtures.named("s32-96000")
    #expect(f.bits == 32 && f.sampleRate == 96_000 && f.expect == .accept)
    #expect(Int64(Fixtures.rawSamples(f).count) == f.frames * Int64(f.channels))
    #expect(FileManager.default.fileExists(atPath: Fixtures.url(Fixtures.named("empty")).path))
}
```

- [ ] **Step 2:** Run `swift test --package-path Packages/PointFlacKit --filter FixtureManifestTests`. Expected: FAIL, `Fixtures` not found.

- [ ] **Step 3: Write `scripts/make-fixtures.py`** (Python 3 standard library only, plus `ffmpeg` and `lame` on PATH)
  - Writes the encoder input:
    - 16-bit: `s16le`.
    - 24- and 32-bit: `s32le` with the value shifted left by `32 − b`. Encode with `-c:a flac -sample_fmt s32 -bits_per_raw_sample <b>`.
  - Writes the `.raw` ground truth.
  - Applies the byte patches listed in the table.
  - Writes `manifest.json`.
  - Must be idempotent. Output: `Packages/PointFlacKit/Sources/PFTestSupport/Resources/Fixtures/`.

- [ ] **Step 4:** Run `python3 scripts/make-fixtures.py && ffprobe -v error -show_entries stream=sample_rate,bits_per_raw_sample -of csv=p=0 Packages/PointFlacKit/Sources/PFTestSupport/Resources/Fixtures/s32-96000.flac`. Expected: `96000,32`. The total fixture folder size must be under 3 MB.

- [ ] **Step 5: Implement `Fixtures` in `PFTestSupport/Fixture.swift`**
  - Uses `Bundle.module`.
  - Raw files are memory-mapped and decoded as little-endian Int32.

- [ ] **Step 6:** Run the Step 2 command. Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "test: add deterministic FLAC fixture set and generator"
```

---

### Task 3: Vendor libFLAC 1.5.0 as the `CFLAC` C target (spike S2)

**Files:**
- Create: `Packages/PointFlacKit/Sources/CFLAC/**` (libFLAC sources), `Sources/CFLAC/include/CFLAC.h`, `Sources/CFLAC/config.h`, `docs/spikes/S2-libflac.md`, `docs/third-party.md`
- Modify: `Package.swift` (add the `CFLAC` target and `CFLACTests`)
- Test: `Packages/PointFlacKit/Tests/CFLACTests/CFLACSmokeTests.swift`

**Interfaces:**
- Produces: `import CFLAC` exposes `FLAC/stream_decoder.h`, `FLAC/metadata.h`, `FLAC/format.h` and `FLAC__VERSION_STRING`.

- [ ] **Step 1: Write the failing test**

```swift
@Test func libflacVersionAndOpensFixture() throws {
    #expect(String(cString: FLAC__VERSION_STRING) == "1.5.0")
    let dec = try #require(FLAC__stream_decoder_new())
    defer { FLAC__stream_decoder_delete(dec) }
    // init_file with a metadata callback that records STREAMINFO, then process_until_end_of_metadata
    // expect sample_rate == 96000, bits_per_sample == 32, channels == 2 for fixture "s32-96000"
}
```

Write it with real callbacks: a C-convention metadata callback writing into a context pointer.

- [ ] **Step 2:** Run `swift test --package-path Packages/PointFlacKit --filter CFLACSmokeTests`. Expected: FAIL, `no such module 'CFLAC'`.

- [ ] **Step 3: Vendor the sources** (after Kiran's download go-ahead)
  - Download `flac-1.5.0.tar.xz` into a new empty scratch folder and record its SHA-256 in `docs/third-party.md`.
  - Copy into `Sources/CFLAC/`:
    - `src/libFLAC/*.c` **except** `ogg_*.c` and `windows_unicode_filenames.c`
    - `src/libFLAC/include/{private,protected}`
    - `include/FLAC/*.h` to `include/FLAC/`
    - `include/share/*.h`
    - `COPYING.Xiph`
  - `config.h` is derived from the tarball's `config.cmake.h.in` for Apple arm64/x86_64:
    - `CPU_IS_LITTLE_ENDIAN 1`, `CPU_IS_BIG_ENDIAN 0`, `ENABLE_64_BIT_WORDS 1`
    - `FLAC__HAS_OGG 0`
    - `HAVE_STDINT_H 1`, `HAVE_INTTYPES_H 1`, `HAVE_FSEEKO 1`, `HAVE_LROUND 1`, `HAVE_SYS_PARAM_H 1`
    - `PACKAGE_VERSION "1.5.0"`
    - no x86 intrinsics, NEON off
  - `CFLAC.h` includes `FLAC/stream_decoder.h`, `FLAC/metadata.h` and `FLAC/format.h`.

- [ ] **Step 4: Add the `CFLAC` target**
  - `cSettings: [.define("HAVE_CONFIG_H"), .headerSearchPath("."), .headerSearchPath("include"), .headerSearchPath("libFLAC/include")]`, with paths adjusted to the copied layout.
  - Silence vendor warnings with `unsafeFlags` **only if** needed. Prefer `-w` via `.unsafeFlags(["-w"])` on that target alone.

- [ ] **Step 5:** Run the Step 2 command. Expected: PASS.

- [ ] **Step 6:** Build for device and simulator: `cd Packages/PointFlacKit && xcodebuild build -scheme PointFlacKit-Package -destination generic/platform=iOS && xcodebuild build -scheme PointFlacKit-Package -destination 'generic/platform=iOS Simulator'`. Expected: both succeed.

- [ ] **Step 7: Write `docs/spikes/S2-libflac.md`** covering: the approach (source target, not a binary XCFramework), the config choices, the build times observed, the result (PASS), and the fallback (sbooth's flac-binary-xcframework).

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "build(flac): vendor libFLAC 1.5.0 as CFLAC target (spike S2)"
```

---

### Task 4: `FlacValidator`, the admission rule

**Files:**
- Create: `Sources/PFFlac/FlacStreamInfo.swift`, `Sources/PFFlac/FlacValidator.swift`
- Modify: `Package.swift` (add `PFFlac`, depending on `PFCore` and `CFLAC`; add `PFFlacTests`)
- Test: `Tests/PFFlacTests/FlacValidatorTests.swift`

**Interfaces:**
- Produces:
  - `public struct FlacStreamInfo: Sendable, Hashable { minBlockSize, maxBlockSize: Int; minFrameSize, maxFrameSize: Int; sampleRate, channels, bitsPerSample: Int; totalFrames: Int64; md5: [UInt8]; var hasMD5: Bool; var format: AudioFormat }`
  - `public enum FlacRejection: Error, Equatable, Sendable { case notFlacName, badMagic, badID3, missingStreamInfo, invalidStreamInfo(String), tooManyBlocks, blockTooLarge, badFrameHeader, frameCRCMismatch, truncated, unreadable }`
  - `public enum FlacValidator { public static func validate(fileAt url: URL) throws(FlacRejection) -> FlacStreamInfo; public static let maxBlocks = 1024; public static let maxBlockBytes = 16 * 1024 * 1024 }`

The rule is spec §5.3, verbatim:
- the real name ends in `.flac` (case-insensitive)
- the file starts with `fLaC`, optionally after a valid ID3v2 tag (synchsafe size bytes < 0x80, plus the footer when the flag is set)
- the first metadata block is a 34-byte STREAMINFO: min block ≥ 16, max ≥ min, `minFrame ≤ maxFrame` when `maxFrame ≠ 0`, rate 1–655 350, bits 4–32
- at most 1024 blocks, each ≤ 16 MiB; large blocks are skipped with `seek`, not read
- the first frame header is valid: sync `0xFFF8/9`, no reserved codes, a valid UTF-8 coded number, CRC-8 with polynomial 0x07

- [ ] **Step 1: Write the failing tests**

```swift
@Test(arguments: Fixtures.all) func admitsExactlyTheRightFixtures(_ f: Fixture) {
    let result = Result { try FlacValidator.validate(fileAt: Fixtures.url(f)) }
    switch f.expect {
    case .accept:
        let info = try? result.get()
        #expect(info?.sampleRate == f.sampleRate && info?.bitsPerSample == f.bits && info?.channels == f.channels)
        #expect(info?.totalFrames == f.frames && info?.hasMD5 == f.hasMD5)
    case .reject:
        #expect(throws: FlacRejection.self) { try result.get() }
        // and the rejection case name equals f.rejection (compare via String(describing:) prefix)
    }
}
@Test func readsAtMostFirstMegabyteForSmallFiles() // validate a fixture through a counting FileHandle wrapper; bytes read < 1_048_576
```

- [ ] **Step 2:** Run `swift test --package-path Packages/PointFlacKit --filter FlacValidatorTests`. Expected: FAIL.

- [ ] **Step 3: Implement `FlacValidator.validate(fileAt:)`** in pure Swift, using `FileHandle` reads. No libFLAC: scanning must be cheap.

- [ ] **Step 4:** Run the Step 2 command. Expected: PASS (24 cases).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(flac): byte-level FLAC admission validator"
```

---

### Task 5: `FlacMetadata` (tags and pictures)

**Files:**
- Create: `Sources/PFFlac/FlacMetadata.swift`
- Modify: `scripts/make-fixtures.py` (pass `-metadata title=… artist=… album=… track=2 date=2023 REPLAYGAIN_TRACK_GAIN="-6.20 dB"` to `s24-48000`, and embed a 16×16 PNG cover with `-disposition:v attached_pic`)
- Test: `Tests/PFFlacTests/FlacMetadataTests.swift`

**Interfaces:**
- Consumes: `FlacValidator`, `FlacStreamInfo`
- Produces:
  - `public struct FlacMetadata: Sendable { streamInfo: FlacStreamInfo; tags: [String: [String]]; pictures: [FlacPicture] }`, where tag keys are uppercased
  - Accessors: `title`, `artist`, `album`, `albumArtist: String?`; `trackNumber`, `discNumber`, `year: Int?`; `trackGainDb`, `albumGainDb: Double?`; `var frontCover: FlacPicture?`
  - `public struct FlacPicture: Sendable { type: Int; mimeType: String; data: Data }`
  - `public enum FlacMetadataReader { static func read(fileAt: URL, includePictures: Bool) throws(FlacRejection) -> FlacMetadata }`

- [ ] **Step 1: Write the failing test**

```swift
@Test func readsTagsAndCover() throws {
    let m = try FlacMetadataReader.read(fileAt: Fixtures.url(Fixtures.named("s24-48000")), includePictures: true)
    #expect(m.title == "Fixture Title" && m.artist == "Fixture Artist" && m.album == "Fixture Album")
    #expect(m.trackNumber == 2 && m.year == 2023 && m.trackGainDb == -6.2)
    #expect(m.frontCover?.mimeType == "image/png" && (m.frontCover?.data.count ?? 0) > 0)
}
@Test func skipsPicturesWhenNotRequested() throws  // pictures.isEmpty
```

- [ ] **Step 2:** Regenerate the fixtures, then run `swift test --package-path Packages/PointFlacKit --filter FlacMetadataTests`. Expected: FAIL.

- [ ] **Step 3: Implement the reader** by parsing VORBIS_COMMENT (type 4, little-endian lengths) and PICTURE (type 6, big-endian lengths).
  - The first value per key wins for the scalar accessors.
  - Track and disc numbers take their leading digits.
  - The year is the first 4 digits of DATE/YEAR.
  - Gain strips a trailing "dB".

- [ ] **Step 4:** Run the Step 2 command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(flac): Vorbis comment and picture metadata reader"
```

---

### Task 6: `FlacDecoder` and `FlacIntegrity`

**Files:**
- Create: `Sources/PFFlac/FlacDecoder.swift`, `Sources/PFFlac/FlacIntegrity.swift`
- Test: `Tests/PFFlacTests/FlacDecoderTests.swift`, `Tests/PFFlacTests/FlacIntegrityTests.swift`

**Interfaces:**
- Consumes: `CFLAC`, `FlacStreamInfo`
- Produces:
  - `public enum FlacDecodeError: Error, Sendable { case openFailed, decodeFailed(String), seekFailed, ioError }`
  - `public final class FlacDecoder` (one thread at a time; not `Sendable`):
    - `init(url: URL) throws(FlacDecodeError)`
    - `var streamInfo: FlacStreamInfo { get }`, `var format: AudioFormat { get }`, `var totalFrames: Int64 { get }`
    - `func read(into buffer: UnsafeMutableBufferPointer<Int32>, maxFrames: Int) throws(FlacDecodeError) -> Int`: interleaved, native range; returns 0 at the end
    - `func seek(toFrame frame: Int64) throws(FlacDecodeError)`: sample-accurate
    - `var currentFrame: Int64 { get }`
    - `var decodeErrorCount: Int { get }`
  - `public enum FlacIntegrityResult: Sendable, Equatable { case intact, damaged, noSignature }` and `public enum FlacIntegrity { static func verify(fileAt: URL) throws(FlacDecodeError) -> FlacIntegrityResult }`

- [ ] **Step 1: Write the failing tests**

```swift
@Test(arguments: Fixtures.all.filter { $0.expect == .accept && $0.name != "corrupt-mid-s16-44100" })
func decodesBitExactly(_ f: Fixture) throws {
    let d = try FlacDecoder(url: Fixtures.url(f))
    var out = [Int32](repeating: 0, count: Int(f.frames) * f.channels)
    var written = 0
    try out.withUnsafeMutableBufferPointer { buf in
        while true {
            let n = try d.read(into: UnsafeMutableBufferPointer(rebasing: buf[(written * f.channels)...]), maxFrames: 1000)
            if n == 0 { break }; written += n
        }
    }
    #expect(Int64(written) == f.frames && out == Fixtures.rawSamples(f))
}
@Test func readsInOddChunkSizesBitExactly()        // s24-96000 with maxFrames 7 → equals raw
@Test func seeksToExactFrame()                      // s24-96000: seek(1234), read 100 frames == raw[1234*2 ..< 1334*2]
@Test func seekToEndThenReadReturnsZero()           // seek(totalFrames) → read == 0
@Test func reportsMidstreamDamageAndContinues()     // corrupt-mid: total 16384 frames; decodeErrorCount >= 1;
                                                    // frames 8192..<12288 all zero; frames outside == raw
@Test func integrityResults()                       // s16-44100 → .intact; nomd5 → .noSignature; corrupt-mid → .damaged
```

- [ ] **Step 2:** Run `swift test --package-path Packages/PointFlacKit --filter "FlacDecoderTests|FlacIntegrityTests"`. Expected: FAIL.

- [ ] **Step 3: Implement `FlacDecoder`** over the libFLAC stream decoder with a file `init`.
  - The write callback interleaves channels into an internal leftover buffer sized to `maxBlockSize × channels`. `read` drains leftovers first, then calls `process_single`.
  - The error callback increments `decodeErrorCount`.
  - Seeking uses `FLAC__stream_decoder_seek_absolute` and clears the leftovers.
  - The callback context is passed via `Unmanaged.passUnretained(self).toOpaque()`.
  - If libFLAC 1.5 doesn't output silence for a CRC-failed frame, change the damaged-block assertion to "frames 8192..<12288 are absent and the total is 12288", and document it in the test.

- [ ] **Step 4: Implement `FlacIntegrity.verify`**
  - `set_md5_checking(true)`, then `process_until_end_of_stream`, then `finish()`.
  - An all-zero STREAMINFO MD5 → `.noSignature`; `finish()` returning false → `.damaged`.

- [ ] **Step 5:** Run the Step 2 command. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(flac): libFLAC-backed streaming decoder, seek and MD5 integrity check"
```

---

### Task 7: Output format policy and signal state (`PFCore`)

**Files:**
- Create: `Sources/PFCore/OutputPort.swift`, `OutputPlan.swift`, `SignalState.swift`, `SignalStrip.swift`
- Test: `Tests/PFCoreTests/OutputPlanTests.swift`, `Tests/PFCoreTests/SignalStateTests.swift`

**Interfaces:**
- Produces:
  - `public enum OutputPort: Sendable, Equatable { case usb(String), wired(String), bluetooth(String), builtIn, airPlay(String), other(String); var isUSB: Bool; var isBluetooth: Bool }`
  - `public struct RateChange: Sendable, Equatable { from: Int; to: Int }`
  - `public struct OutputPlan: Sendable, Equatable { enum Client { case float32, int32 }; client: Client; clientSampleRate: Int; resample: RateChange?; reduceTo24: Bool }`
  - `public struct OutputCapabilities: Sendable { var int32Passthrough: Bool; static let current: OutputCapabilities }`, where `current` is set from spike S1's result in Task 12
  - `public enum OutputFormatPolicy { static func plan(source: AudioFormat, hardwareRate: Int, capabilities: OutputCapabilities) -> OutputPlan }`
  - `public struct SignalState: Sendable, Equatable { source: AudioFormat?; plan: OutputPlan?; hardwareRate: Int?; port: OutputPort?; systemVolume: Float?; activeProcessing: [String]; scrubbing: Bool; var indicator: SignalIndicator; var volumeWarningPercent: Int? }`
  - `public enum SignalIndicator: Equatable, Sendable { case idle, pure, resampled(RateChange), depthReduced(from: Int, to: Int), processing(Int), scrubbing, bluetoothLossy }`
  - `public enum SignalStrip { static func text(_ s: SignalState) -> String }`

**Policy rules** (spec §5.2):
- `clientSampleRate = hardwareRate` **always**.
- `resample = hardwareRate ≠ source.sampleRate ? RateChange(source.sampleRate, hardwareRate) : nil`.
- Client is `.int32` only when `bits > 24 && capabilities.int32Passthrough && resample == nil`; otherwise `.float32`.
- `reduceTo24 = bits > 24 && client == .float32`.

**Indicator precedence:** scrubbing > bluetoothLossy > processing > resampled > depthReduced > pure. `idle` when `source == nil`. `volumeWarningPercent` is set only when the port is USB and the volume is < 1.0.

**Strip text:**
- Format: `"FLAC · <depth> · <hardware rate> · <label>"`.
- Labels: `● Pure`, `● Resampled 96→48`, `● 32→24-bit`, `● Processing`, `● Scrubbing`, `● Bluetooth (lossy)`.
- Rates in labels use kHz shorthand (44.1, 48, 88.2, 96, 176.4, 192, 352.8, 384).
- Idle text: `"No record"`.

- [ ] **Step 1: Write the failing tests** (table-driven)

```swift
@Test func plans() {
    let cap = OutputCapabilities(int32Passthrough: true), no32 = OutputCapabilities(int32Passthrough: false)
    #expect(OutputFormatPolicy.plan(source: .init(sampleRate: 44_100, bitsPerSample: 16, channels: 2), hardwareRate: 44_100, capabilities: cap)
            == OutputPlan(client: .float32, clientSampleRate: 44_100, resample: nil, reduceTo24: false))
    #expect(OutputFormatPolicy.plan(source: .init(sampleRate: 96_000, bitsPerSample: 24, channels: 2), hardwareRate: 48_000, capabilities: cap)
            == OutputPlan(client: .float32, clientSampleRate: 48_000, resample: .init(from: 96_000, to: 48_000), reduceTo24: false))
    #expect(OutputFormatPolicy.plan(source: .init(sampleRate: 96_000, bitsPerSample: 32, channels: 2), hardwareRate: 96_000, capabilities: cap).client == .int32)
    #expect(OutputFormatPolicy.plan(source: .init(sampleRate: 96_000, bitsPerSample: 32, channels: 2), hardwareRate: 96_000, capabilities: no32)
            == OutputPlan(client: .float32, clientSampleRate: 96_000, resample: nil, reduceTo24: true))
    #expect(OutputFormatPolicy.plan(source: .init(sampleRate: 192_000, bitsPerSample: 32, channels: 2), hardwareRate: 48_000, capabilities: cap)
            == OutputPlan(client: .float32, clientSampleRate: 48_000, resample: .init(from: 192_000, to: 48_000), reduceTo24: true))
}
@Test(arguments: [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 384_000]) func clientRateAlwaysEqualsHardware(_ hw: Int)
@Test func stripTexts() {
    // 24/96 on USB at 96 kHz, nothing active → "FLAC · 24-bit · 96 kHz · ● Pure"
    // 24/96 at 48 kHz → "FLAC · 24-bit · 48 kHz · ● Resampled 96→48"
    // 32/96 at 96 kHz, no int32 → "FLAC · 32-bit · 96 kHz · ● 32→24-bit"
    // 32/192 at 48 kHz → "● Resampled 192→48" (precedence over depth)
    // Bluetooth port → "● Bluetooth (lossy)"; scrubbing true → "● Scrubbing"; activeProcessing ["EQ"] → "● Processing"
    // nil source → "No record"
}
@Test func volumeWarningOnlyOnUSB()   // usb + 0.8 → 80; builtIn + 0.8 → nil; usb + 1.0 → nil
@Test func neverSaysBitPerfect()      // no strip text, for any state in the tables above, contains "bit-perfect" (case-insensitive)
```

- [ ] **Step 2:** Run `swift test --package-path Packages/PointFlacKit --filter "OutputPlanTests|SignalStateTests"`. Expected: FAIL.
- [ ] **Step 3:** Implement the four files exactly as the rules above.
- [ ] **Step 4:** Run the Step 2 command. Expected: PASS.
- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): output format policy and honest signal readout"
```

---

### Task 8: `TPDFDither` and `SampleRateConverter` (`PFDSP`)

**Files:**
- Create: `Sources/PFDSP/TPDFDither.swift`, `Sources/PFDSP/SampleRateConverter.swift`
- Modify: `Package.swift` (add `PFDSP`, depending on `PFCore`; add `PFDSPTests`)
- Test: `Tests/PFDSPTests/TPDFDitherTests.swift`, `Tests/PFDSPTests/SampleRateConverterTests.swift`

**Interfaces:**
- Produces:
  - `public struct TPDFDither: Sendable { init(seed: UInt64); mutating func reduce32To24(_ samples: UnsafeMutableBufferPointer<Int32>) }`
    - Input: full-range Int32.
    - Output: multiples of 256, saturating at `Int32.max & ~255` and `Int32.min`.
    - Noise: the sum of two independent uniform values in [−128, 127] from xorshift64*, added before rounding to the nearest 256.
  - `public final class SampleRateConverter { init(inputRate: Int, outputRate: Int, channels: Int) throws; func process(_ input: UnsafeBufferPointer<Float>, frames: Int, into output: inout [Float]) -> Int; func flush(into output: inout [Float]) -> Int }`
    - Interleaved Float32.
    - Wraps `AVAudioConverter` with `sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering` and `sampleRateConverterQuality = .max`.
    - Runs on the decode thread only, never the render thread.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func ditherOutputsMultiplesOf256WithinTwoLSB()   // 100_000 random Int32 → all % 256 == 0, |out - in| <= 512
@Test func ditherIsUnbiased()                           // constant input 1000 repeated 100_000 → |mean(out) - 1000| < 4
@Test func ditherSaturatesWithoutWrap()                 // Int32.max → Int32.max & ~255; Int32.min → Int32.min
@Test func ditheredValuesConvertExactlyToFloat32()      // Float(out) / 2^31 * 2^31 == Double(out) for all outputs
@Test func resamplerPreservesPassbandSine()             // 1 kHz at −1 dBFS, 96k→48k, 1 s; skip the first 2048 output frames; RMS within ±0.05 dB of expected
@Test func resamplerRejectsAboveNewNyquist()            // 30 kHz sine at 96k → 48k: output RMS < −90 dBFS
@Test func resamplerFrameCountMatchesRatio()            // 96_000 frames in + flush → 48_000 ± 64 out; also 44_100 → 48_000 ± 64
```

- [ ] **Step 2:** Run `swift test --package-path Packages/PointFlacKit --filter PFDSPTests`. Expected: FAIL.
- [ ] **Step 3:** Implement both types per the interfaces.
- [ ] **Step 4:** Run the Step 2 command. Expected: PASS.
- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(dsp): TPDF 32→24 dither and mastering-quality resampler"
```

---

### Task 9: `SampleRing`, the lock-free single-producer/single-consumer ring buffer

**Files:**
- Create: `Sources/PFAudio/SampleRing.swift`
- Modify: `Package.swift` (add `PFAudio`, depending on `PFCore`, `PFFlac` and `PFDSP`; add `PFAudioTests`)
- Test: `Tests/PFAudioTests/SampleRingTests.swift`

**Interfaces:**
- Produces: `public final class SampleRing<Element: BitwiseCopyable>: @unchecked Sendable`, with:
  - `init(capacity: Int)` (rounded up to a power of two)
  - `func write(_ src: UnsafeBufferPointer<Element>) -> Int` (producer only)
  - `func read(into dst: UnsafeMutableBufferPointer<Element>) -> Int` (consumer only; real-time safe)
  - `var availableToRead: Int`, `var availableToWrite: Int`
  - `func reset()` (only while both sides are stopped)
- Head and tail are `Synchronization.Atomic<Int>`, loaded with `.acquiring` and stored with `.releasing`. Storage is one `UnsafeMutablePointer<Element>` allocated in `init`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func wrapsAroundPreservingOrder()          // capacity 8; write 6, read 4, write 6 → reads yield 0...11 in order
@Test func writeReturnsPartialWhenFull()         // capacity 8; write 10 → returns 8
@Test func concurrentProducerConsumerIsExact()   // producer thread writes Int32 0..<2_000_000 in random chunks 1...4096;
                                                 // consumer thread reads random chunks; every value equals its index; finishes < 5 s
```

- [ ] **Step 2:** Run `swift test --package-path Packages/PointFlacKit --filter SampleRingTests`. Expected: FAIL.
- [ ] **Step 3:** Implement `SampleRing`.
- [ ] **Step 4:** Run the Step 2 command, plus `--sanitize=thread`. Expected: PASS, with no TSan reports.
- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(audio): lock-free SPSC sample ring"
```

---

### Task 10: `PlaybackPipeline` and `RenderSource` (host-tested)

**Files:**
- Create: `Sources/PFAudio/PCMDecoding.swift`, `RenderSource.swift`, `AudioOutput.swift`, `PlaybackPipeline.swift`, `Sources/PFTestSupport/FakeOutput.swift`
- Modify: `Package.swift` (`PFTestSupport` now also depends on `PFAudio`, for `FakeOutput`)
- Test: `Tests/PFAudioTests/PlaybackPipelineTests.swift`

**Interfaces:**
- Consumes:
  - `FlacDecoder` (Task 6)
  - `OutputFormatPolicy`, `OutputPlan`, `OutputCapabilities` (Task 7)
  - `TPDFDither`, `SampleRateConverter` (Task 8)
  - `SampleRing` (Task 9)
- Produces:
  - `public protocol PCMDecoding: AnyObject { var format: AudioFormat { get }; var totalFrames: Int64 { get }; func read(into: UnsafeMutableBufferPointer<Int32>, maxFrames: Int) throws -> Int; func seek(toFrame: Int64) throws }`, with `extension FlacDecoder: PCMDecoding`
  - `public struct PlaybackItem: Sendable, Hashable, Identifiable { id: String; url: URL; format: AudioFormat; totalFrames: Int64 }`
  - `public final class RenderSource: @unchecked Sendable`, with:
    - `func render(into: UnsafeMutableRawPointer, frames: Int) -> Int`: real-time safe; fills silence on underrun and returns the frames of real audio
    - `var renderedFrames: Int64` (atomic)
  - `public protocol AudioOutput: AnyObject { func configure(_ plan: OutputPlan, channels: Int) throws; func start() throws; func stop(); var source: RenderSource? { get set } }`
  - `public enum PipelineEvent: Sendable, Equatable { case planChanged(OutputPlan), trackStarted(Int), trackEnded(Int), itemFailed(Int, String), queueEnded }`
  - `public final class PlaybackPipeline: @unchecked Sendable`:
    - `init(output: AudioOutput, capabilities: OutputCapabilities, negotiateRate: @escaping @Sendable (Int) async -> Int, makeDecoder: @escaping @Sendable (PlaybackItem) throws -> PCMDecoding)`
    - `func start(_ items: [PlaybackItem], at index: Int, fromFrame: Int64) async`
    - `func seek(toFrame: Int64) async`
    - `func stop()`
    - `var events: AsyncStream<PipelineEvent>`
    - `var position: (index: Int, frame: Int64)`, derived from rendered frames, not decoded frames
  - `FakeOutput: AudioOutput` (in `PFTestSupport`): `func pull(frames: Int)`, `var capturedFloat: [Float]`, `var capturedInt32: [Int32]`, `var plans: [OutputPlan]`

**Behaviour** (spec §5.2):
- The decode loop runs on a dedicated `Thread` at `.userInitiated` QoS. It converts each block per the plan:
  - Float32 path: `Float(v) / 2^(b−1)`, after `TPDFDither` when `reduceTo24`.
  - Int32 path: `v << (32 − b)`.
  - The resampler runs when `resample != nil`.
- The converted block is written to the ring.
- A same-plan next item continues into the same ring: gapless, sample-exact.
- A different plan at a boundary:
  1. let the ring drain
  2. stop the output
  3. call `negotiateRate(next.sampleRate)`
  4. recompute the plan, `configure`, and `start`
  5. emit `.planChanged`
- Track boundaries are tracked with a marker queue keyed by absolute rendered frame. `trackStarted` and `trackEnded` fire when the boundary is **rendered**.
- A `seek` cancels the pending decode, resets the ring, then seeks the decoder. A newer seek supersedes an older one.
- A decoder error on read emits `.itemFailed(index, message)` and moves to the next item.
- The ring capacity is 0.5 s at the current rate; the decode block is 4096 frames.

- [ ] **Step 1: Write the failing tests** (FakeOutput pulls 512-frame chunks until `queueEnded`)

```swift
@Test func pureFloatPathIsBitExact()         // s16-44100 and s24-96000, negotiate returns source rate → capturedFloat == raw / 2^(b-1)
@Test func int32PathIsBitExact()             // s32-96000, int32Passthrough true → capturedInt32 == raw
@Test func gaplessJoinSameFormat()           // [s24-48000, s24-48000] → 8192 frames, exact concatenation, one planChanged only
@Test func formatChangeBetweenTracksReconfigures()  // [s16-44100, s24-96000] → plans[1].clientSampleRate == 96_000; second segment exact
@Test func resamplesWhenHardwareDiffers()    // s24-96000 with negotiate returning 48_000 → plan.resample == 96k→48k; captured frames 2048 ± 64
@Test func decoderFailureSkipsToNextItem()   // item 0 decoder throws after 1000 frames → events contain .itemFailed(0, _) then .trackStarted(1); item 1 exact
@Test func seekSpamLatestWins()              // during playback of s24-96000 issue 50 seeks ending at 3000 → next captured frames == raw[3000...]
@Test func midstreamDamagePlaysThrough()     // corrupt-mid → no itemFailed; 16384 frames captured
@Test func seekCompletesWithin50ms()         // time from seek(toFrame:) call to first non-silent frame available < 0.050 s
@Test func eventsFireOnRenderedBoundary()    // trackEnded(0) observed only after FakeOutput pulled ≥ 4096 frames
```

- [ ] **Step 2:** Run `swift test --package-path Packages/PointFlacKit --filter PlaybackPipelineTests`. Expected: FAIL.
- [ ] **Step 3:** Implement the five source files to satisfy the behaviour. `RenderSource.render` touches only preallocated memory and atomics.
- [ ] **Step 4:** Run the Step 2 command, with `--sanitize=thread` as well. Expected: PASS, with no TSan reports.
- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(audio): gapless decode→ring→render pipeline with format-aware boundaries"
```

---

### Task 11: Audio session and sample-rate negotiation (spike S3)

**Files:**
- Create: `Sources/PFAudio/AudioSessionControlling.swift`, `Sources/PFAudio/iOS/SystemAudioSession.swift`, `Sources/PFTestSupport/FakeSession.swift`, `docs/spikes/S3-rate-negotiation.md`
- Test: `Tests/PFAudioTests/OutputPortMappingTests.swift` (host), `Tests/PFAudioTests/SystemAudioSessionTests.swift` (`#if os(iOS)`)

**Interfaces:**
- Produces:
  - `public protocol AudioSessionControlling: AnyObject, Sendable { func activate() async throws; func requestSampleRate(_ hz: Int) async -> Int; var currentPort: OutputPort { get }; var outputVolume: Float { get }; var events: AsyncStream<SessionEvent> { get } }`
  - `public enum SessionEvent: Sendable, Equatable { case routeChanged(RouteChangeReason, OutputPort), interruptionBegan, interruptionEnded(shouldResume: Bool), volumeChanged(Float), mediaServicesReset }`
  - `public enum RouteChangeReason: Sendable { case oldDeviceUnavailable, newDeviceAvailable, other }`
  - `extension OutputPort { init(portType: String, name: String) }` (pure, host-testable):
    - `USBAudio` → `.usb`
    - `Headphones` / `LineOut` → `.wired`
    - `BluetoothA2DPOutput`, `BluetoothLE`, `BluetoothHFP` → `.bluetooth`
    - `Speaker` → `.builtIn`
    - `AirPlay` → `.airPlay`
  - `SystemAudioSession: AudioSessionControlling` (iOS):
    - category `.playback`, mode `.default`, policy `.longFormAudio`
    - `requestSampleRate`: `setActive(false)`, then `setPreferredSampleRate`, then `setActive(true)`, then return `Int(sampleRate)`
    - observes `routeChangeNotification`, `interruptionNotification`, `mediaServicesWereResetNotification` and KVO on `outputVolume`
  - `FakeSession` (in `PFTestSupport`): a scriptable rate response; `func emit(_ e: SessionEvent)`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func mapsPortTypes()  // "USBAudio"→.usb(name), "Headphones"→.wired, "BluetoothA2DPOutput"→.bluetooth, "Speaker"→.builtIn, "AirPlay"→.airPlay
#if os(iOS)
@Test func requestedRateIsReadBack() async throws  // for 44_100, 48_000, 96_000: result > 0 && result == Int(AVAudioSession.sharedInstance().sampleRate)
                                                   // record (requested, actual, port) with print("S3:", …) for the spike doc
#endif
```

- [ ] **Step 2:** Run `swift test --package-path Packages/PointFlacKit --filter OutputPortMappingTests`. Expected: FAIL.
- [ ] **Step 3:** Implement `AudioSessionControlling`, the `OutputPort` mapping, `SystemAudioSession` and `FakeSession`.
- [ ] **Step 4:** Run `swift test …` (host) and then `cd Packages/PointFlacKit && xcodebuild test -scheme PointFlacKit-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:PFAudioTests/SystemAudioSessionTests`. Expected: PASS. Copy the `S3:` lines into `docs/spikes/S3-rate-negotiation.md`, under a "Simulator" heading; the "iPhone 17 Pro + EarPods" section stays pending until the device steps can run.
- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(audio): audio session control and rate negotiation (spike S3)"
```

---

### Task 12: RemoteIO output and bit-exact capture (spike S1)

**Files:**
- Create: `Sources/PFAudio/iOS/RemoteIOOutput.swift`, `docs/spikes/S1-output-path.md`
- Modify: `Sources/PFCore/OutputPlan.swift` (set `OutputCapabilities.current` from the S1 result)
- Test: `Tests/PFAudioTests/RemoteIOOutputTests.swift` (`#if os(iOS)`)

**Interfaces:**
- Consumes: `AudioOutput`, `RenderSource`, `OutputPlan`, `SystemAudioSession`
- Produces: `public final class RemoteIOOutput: AudioOutput`, with:
  - `init() throws` (creates `kAudioUnitSubType_RemoteIO`)
  - `configure`: sets the stream format on input scope bus 0 to interleaved packed native-endian Float32 or signed Int32 (32 bits) at `plan.clientSampleRate`, then initialises the unit; throws `AudioOutputError.formatRejected(OSStatus)` if refused
  - `#if DEBUG` `func installCapture(byteCapacity: Int)` and `var capturedBytes: Data` (the capture buffer is preallocated; the render callback only `memcpy`s)
  - `var firstRenderLatency: Duration?` (start to first callback)

- [ ] **Step 1: Write the failing tests** (simulator)

```swift
@Test func acceptsFloat32Client() throws       // configure(.float32 @ session rate) does not throw
@Test func reportsInt32ClientSupport() throws  // configure(.int32 @ session rate): record "S1: int32 accepted|rejected(<status>)"
@Test(arguments: ["s16-48000", "s24-48000", "s32-48000"])   // pick the 44100 variants when the session rate is 44100
func capturedBytesMatchSource(_ name: String) async throws
    // run PlaybackPipeline with RemoteIOOutput + capture; wait for queueEnded; compare captured bytes to raw converted per plan:
    // Float32 = raw / 2^(b-1) (with TPDFDither(seed: same) when reduceTo24) or Int32 = raw << (32-b); expect exact equality
@Test func firstRenderUnder150ms() async throws  // firstRenderLatency < .milliseconds(150)
```

- [ ] **Step 2:** Run `cd Packages/PointFlacKit && xcodebuild test -scheme PointFlacKit-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:PFAudioTests/RemoteIOOutputTests`. Expected: FAIL.
- [ ] **Step 3: Implement `RemoteIOOutput`**
  - The render callback is a `@convention(c)` function. Its `inRefCon` is an `Unmanaged` pointer to a small final class that holds the `RenderSource` and the capture pointer.
  - No Swift arrays, closures or locks on the render path.
- [ ] **Step 4:** Run the Step 2 command. Expected: PASS for Float32 at 16 and 24 bit.
  - If the Int32 client is accepted and `s32-*` captures are exact, set `OutputCapabilities.current = .init(int32Passthrough: true)`. Otherwise set it to false and confirm that the `s32` capture is exact against the dithered Float32 expectation.
- [ ] **Step 5: Write `docs/spikes/S1-output-path.md`** with:
  - the API choice (RemoteIO)
  - whether the Int32 client is accepted
  - the capture results per depth
  - the first-render latency
  - the device section left **pending** (iPhone 17 Pro needs the Xcode beta), with the exact steps to rerun later
- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(audio): RemoteIO output with bit-exact capture verification (spike S1)"
```

---

### Task 13: `Player` facade, Now Playing, routes and interruptions

**Files:**
- Create: `Sources/PFAudio/QueueItem.swift`, `Player.swift`, `NowPlayingPublishing.swift`, `iOS/SystemNowPlaying.swift`
- Test: `Tests/PFAudioTests/PlayerTests.swift`

**Interfaces:**
- Consumes:
  - `PlaybackPipeline` and `PipelineEvent` (Task 10)
  - `AudioSessionControlling` and `SessionEvent` (Task 11)
  - `SignalState` (Task 7)
- Produces:
  - `public struct QueueItem: Sendable, Hashable, Identifiable { id: String; url: URL; title: String; artist: String; album: String; format: AudioFormat; totalFrames: Int64; artwork: Data? }`, where `var playbackItem: PlaybackItem`
  - `public protocol NowPlayingPublishing: AnyObject { func show(_ item: QueueItem, elapsed: Duration, playing: Bool); func clear(); var onCommand: ((RemoteCommand) -> Void)? { get set } }`
  - `public enum RemoteCommand: Sendable { case play, pause, toggle, next, previous, seek(Duration) }`
  - `@MainActor @Observable public final class Player`:
    - `enum Status: Equatable { case idle, preparing, playing, paused, ended, failed(String) }`
    - `private(set) var status: Status`, `private(set) var queue: [QueueItem]`, `private(set) var currentIndex: Int?`
    - `private(set) var position: Duration`, updated at 10 Hz while playing
    - `private(set) var signal: SignalState`
    - `init(session: AudioSessionControlling, output: AudioOutput, capabilities: OutputCapabilities, nowPlaying: NowPlayingPublishing, makeDecoder: @escaping @Sendable (PlaybackItem) throws -> PCMDecoding)`
    - `func play(_ items: [QueueItem], startingAt: Int) async`, `func pause()`, `func resume()`, `func togglePlayPause()`
    - `func seek(to: Duration) async`, `func next() async`
    - `func previous() async`: restarts the current track when position > 3 s (Runout's `RESTART_WINDOW_MS = 3000`); otherwise goes to the previous track
  - `SystemNowPlaying` (iOS): writes `MPNowPlayingInfoCenter`, and wires `MPRemoteCommandCenter` play, pause, toggle, next, previous and `changePlaybackPosition` to `onCommand`.

- [ ] **Step 1: Write the failing tests** (host: `FakeSession`, `FakeOutput`, a fake `NowPlayingPublishing`)

```swift
@Test func playsQueueAndEnds()                          // 2 items → status .playing, then .ended after the FakeOutput drains
@Test func pausesWhenOutputUnplugged()                  // emit .routeChanged(.oldDeviceUnavailable, .builtIn) → status .paused
@Test func resumesAfterInterruptionOnlyWhenAllowed()    // began → .paused; ended(true) → .playing; began, ended(false) → .paused
@Test func previousRestartsAfterThreeSeconds()          // position 4 s → previous() → same index, position 0
@Test func signalFollowsRoute()                         // route → .bluetooth("AirPods") → signal.indicator == .bluetoothLossy
@Test func usbVolumeWarning()                           // port .usb, volume 0.8 → signal.volumeWarningPercent == 80
@Test func nowPlayingShowsCurrentTrack()                // fake receives show(item.title == "Fixture Title")
@Test func remoteCommandsDrivePlayer()                  // onCommand(.pause) → .paused; .next → currentIndex 1
```

- [ ] **Step 2:** Run `swift test --package-path Packages/PointFlacKit --filter PlayerTests`. Expected: FAIL.
- [ ] **Step 3:** Implement the files above.
- [ ] **Step 4:** Run the Step 2 command. Expected: PASS.
- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(audio): Player facade with Now Playing, route and interruption handling"
```

---

### Task 14: Import inbox and debug app

**Files:**
- Create: `Sources/PFLibrary/ImportInbox.swift`, `App/AppModel.swift`, `App/Debug/DebugLibraryView.swift`, `App/Debug/DebugNowPlayingView.swift`, `App/Debug/Fixtures/{s24-48000,s16-44100,renamed-mp3}.flac`, `AppUITests/PlaybackSmokeTests.swift`
- Modify: `App/PointFlacApp.swift`, `project.yml` (add the `PFAudio` and `PFLibrary` products; `App/Debug/Fixtures` is a resource only in Debug), `Package.swift` (add `PFLibrary`, depending on `PFFlac`; add `PFLibraryTests`)
- Test: `Tests/PFLibraryTests/ImportInboxTests.swift`, `AppUITests/PlaybackSmokeTests.swift`

**Interfaces:**
- Consumes: `FlacValidator`, `FlacMetadataReader` (Tasks 4–5); `Player`, `QueueItem`, `SystemAudioSession`, `RemoteIOOutput`, `SystemNowPlaying` (Tasks 11–13); `SignalStrip` (Task 7)
- Produces:
  - `public struct ImportedFile: Sendable, Hashable, Identifiable { id: String; url: URL; metadata summary: title, artist, album; format: AudioFormat; totalFrames: Int64 }`
  - `public struct ImportRejection: Sendable, Hashable { fileName: String; reason: FlacRejection; var message: String }`
    - Messages: `badMagic` → "Not a FLAC file"; `notFlacName` → "Only .flac files can be added"; any other reason → "Damaged or incomplete FLAC".
  - `public actor ImportInbox`:
    - `init(libraryFolder: URL)`
    - `func importFiles(_ urls: [URL]) async -> (added: [ImportedFile], rejected: [ImportRejection])`
      - Copies into `libraryFolder`, starting and stopping security-scoped access around each source.
      - Skips duplicates with the same name and byte size.
      - Validates **before** copying.
    - `func list() async -> [ImportedFile]`
  - The `AppModel` (`@MainActor @Observable`) owns `Player` and `ImportInbox`, with the library folder at `Documents/Library`.
    - Launch argument `-PFPreloadFixtures`: DEBUG only; imports `App/Debug/Fixtures/*` on launch.
    - The debug UI uses the accessibility identifiers `importButton`, `trackRow-<title>`, `signalStrip`, `playPauseButton`.

- [ ] **Step 1: Write the failing tests**

```swift
// PFLibraryTests
@Test func importsValidAndRejectsDisguised() async  // [s24-48000, renamed-mp3] → added 1, rejected 1 with message "Not a FLAC file"; file exists in folder
@Test func skipsDuplicates() async                  // import s24-48000 twice → second call added 0, list().count == 1
@Test func rejectsBeforeCopying() async             // renamed-mp3 is never present in libraryFolder
```

```swift
// AppUITests/PlaybackSmokeTests.swift (XCTest)
func testPreloadedFixturePlaysWithHonestStrip() {
    let app = XCUIApplication(); app.launchArguments = ["-PFPreloadFixtures"]; app.launch()
    app.buttons["trackRow-Fixture Title"].tap()
    let strip = app.staticTexts["signalStrip"]
    XCTAssertTrue(strip.waitForExistence(timeout: 2))
    XCTAssertTrue(strip.label.hasPrefix("FLAC · 24-bit · "))
    XCTAssertTrue(strip.label.contains("●"))
    XCTAssertFalse(strip.label.localizedCaseInsensitiveContains("bit-perfect"))
}
func testDisguisedMP3IsNotListed()   // no "trackRow-" element for the mp3; a rejection text "Not a FLAC file" exists
```

- [ ] **Step 2:** Run `swift test --package-path Packages/PointFlacKit --filter ImportInboxTests`. Expected: FAIL.
- [ ] **Step 3:** Implement `ImportInbox`.
- [ ] **Step 4:** Run the Step 2 command. Expected: PASS.
- [ ] **Step 5: Implement the debug app**
  - `DebugLibraryView` uses `.fileImporter(allowedContentTypes: [UTType(filenameExtension: "flac")!], allowsMultipleSelection: true)` and lists the tracks and rejections.
  - `DebugNowPlayingView` shows the title, artist, `SignalStrip.text(player.signal)` (id `signalStrip`), play/pause, a seek `Slider`, and previous and next.
- [ ] **Step 6:** Run `scripts/bootstrap.sh && xcodebuild test -scheme PointFlac -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`. Expected: both UI tests PASS.
- [ ] **Step 7: Manual simulator check.** Import `s32-48000.flac` through the Files picker. It plays, and the strip shows `FLAC · 32-bit · <rate> · ● …` matching the S1 result. Record the result in `docs/spikes/S1-output-path.md`.
- [ ] **Step 8: Device check** (pending the Xcode beta). Install on the iPhone 17 Pro with EarPods and confirm:
  - `s16-44100` and `s24-48000` show "● Pure" at 44.1 kHz and 48 kHz respectively.
  - `s24-96000` shows "● Resampled 96→48".
  - Unplugging pauses playback.
  - Lock-screen controls work.

  Record the results in S1 and S3.
- [ ] **Step 9: Commit**

```bash
git add -A && git commit -m "feat(app): import inbox and debug player UI for the audio core"
```

---

### Task 15: CI workflow and README build section

**Files:**
- Create: `.github/workflows/ci.yml`
- Modify: `README.md`, `scripts/test.sh` (accept `PF_SIM_NAME` from the environment)

**Interfaces:**
- Consumes: `scripts/test.sh` (Task 1)

- [ ] **Step 1: Write `ci.yml`**
  - Triggers: `push` and `pull_request` on `main`.
  - One job on `runs-on: macos-26`; if that label isn't available on the first run, use the newest macOS image whose Xcode supports the iOS 26 SDK.
  - Steps:
    1. `actions/checkout@v4`
    2. `sudo xcode-select -s` the newest Xcode 26.x on the image
    3. `brew install xcodegen`
    4. `xcodebuild -downloadPlatform iOS` if no iOS 26 simulator exists
    5. `scripts/bootstrap.sh`
    6. `scripts/test.sh`
  - Upload `xcresult` bundles as artifacts on failure.

- [ ] **Step 2: Update the README build section**
  - Requirements: Xcode 26.6+, `brew install xcodegen`.
  - Commands: `scripts/bootstrap.sh`, `scripts/test.sh`, open `PointFlac.xcodeproj`.
  - A note that installing on a device with a beta iOS needs the matching Xcode beta.

- [ ] **Step 3:** Run `scripts/test.sh` locally. Expected: every stage passes. Then validate the workflow syntax with `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml'))"`. If PyYAML is missing, `gh workflow view` works after the push instead.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "ci: GitHub Actions build and test workflow"
```

- [ ] **Step 5: Create the GitHub repo and push** (only after Kiran's explicit go-ahead in that message): `gh repo create kiraa06/pointFlac --public --source . --push`. Then `gh run watch` for the first CI run. Expected: green. If the runner label or Xcode selection fails, fix `ci.yml` in a follow-up commit, which also needs a go-ahead before it's pushed.
