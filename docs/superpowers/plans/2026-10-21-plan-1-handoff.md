# Plan 1 hand-off: rulings, deferred items, pending device checks

Plan 1 (foundation & audio core) was executed task by task, with a review after each task, a whole-branch review and one fix wave. This note keeps what later plans need from the execution ledger: every ruling made during execution, which binds unless a later spec change says otherwise, and every item deliberately deferred. Plans 2 and 3 should open by reading the **Entry gates**.

## Entry gates

**Before Plan 2 (library and search):**

- ImportInbox is a seam, not a library. Add stable file identity, NSFileCoordinator reads, a file-size bound (spec §5.8) and off-pool I/O. Replace `list()`'s full re-parse with an index.
- FlacMetadata hostile-body tests (T5).
- `trackStarted` updates `format` but not `totalFrames` for replaced files (M5).

**Before Plan 3 (Deck and Cover UI):** measure on the iPhone first, using the OSSignposter intervals in `Telemetry.swift`.

- Non-blocking engine retire (I5). The main actor currently waits on the AudioUnit stop.
- Seek pre-decode overlap (I6). The handshake needs two render cycles, which could come close to the 50 ms budget on the device's I/O period.
- Throttle the Now Playing republish on seek, for scrubbing.
- Add a timestamped position anchor for 120 Hz platter animation, a side-level `seek(to:time:)`, and a variable-rate scrub render mode.
- Paused refresh after a media reset can show a stale rate (M1).
- A spec decision is needed: built-in speaker processing, and any copy claiming the strip sees every alteration.

**Before Plan 4 (DSP):**

- The DSP insertion point is `DecodeSession.play()`, between read and convert.
- The pipeline must report the processing it actually applied, so "● Processing" is never driven by UI settings.
- Mid-track parameter changes need a live path.

## Pending device checks (iPhone 17 Pro, iOS 27.2 beta)

The steps are in `docs/spikes/S1-output-path.md` and `docs/spikes/S3-rate-negotiation.md`:

- **EarPods** (24-bit/48 kHz cap):
  - 16/44.1 and 24/48 show Pure.
  - 96 kHz shows Resampled 96→48.
  - 32-bit shows 32→24-bit.
  - Unplugging pauses.
  - Lock-screen controls work.
  - The hardware-side rate equals the client rate.
- **Signposts:**
  - play → first sample < 150 ms
  - seek < 50 ms
  - the retire stall
- **devicectl:** leading-dash app arguments are forwarded.
- **Later, with a 32-bit USB DAC:** the evidence for flipping `OutputCapabilities.current` (R13).

## Rulings made during execution

- Ruling R1: in T1, PFCoreTests has no PFTestSupport dependency; T2 adds it and wires every test target from then on — the plan's intent is staged target creation — cost if wrong: trivial.
- Ruling R2: FlacValidator gets an internal `validate(reader:)` overload over a small byte-reader protocol; the public `validate(fileAt:)` wraps a FileHandle reader; tests use `@testable import` with a counting reader — keeps the public API exactly as planned — cost if wrong: trivial.
- Ruling R3: PlaybackPipeline.init gains `ditherSeed: UInt64 = 0x9E3779B97F4A7C15` (default parameter) and uses one TPDFDither per track, processing samples in order. T12's expectation uses the same seed over the whole raw sequence — needed for a reproducible bit-exact test — cost if wrong: small API addition.
- Ruling R4: debug fixtures are included as app resources, but excluded from Release via `EXCLUDED_SOURCE_FILE_NAMES[config=Release]` in project.yml, and only read under `#if DEBUG` — this meets "Debug-only" — cost if wrong: about 100 KB in a release build.
- Ruling R5: while the simulator runtime is missing, simulator builds use `-destination 'generic/platform=iOS Simulator'` (no runtime needed), and simulator *test* steps are deferred until the runtime is installed. The controller checks before T11. Host `swift test` gates every task — cost if wrong: simulator-only failures surface later.
- Ruling R6: scripts/test.sh stage 3 must use scheme `PointFlacKit` (xcodebuild in Packages/PointFlacKit; discovered in T3) and `test` builds CFLAC via test targets — fix carried into the next fix round or Task 4 dispatch — cost if wrong: stage 3 fails
- Ruling R7: accept `.define("NDEBUG")` on CFLAC (T6) — matches libFLAC release builds; without it libFLAC writes resync messages to stderr in shipped builds — cost if wrong: libFLAC internal asserts not exercised in debug builds
- Ruling R8: revert R6 — with >1 library product Xcode names the aggregate scheme `PointFlacKit-Package` (plan was right; `PointFlacKit` only existed while there was one product). Fix carried into Task 7 dispatch — cost if wrong: stage 3 fails
- Ruling R9: (T9 Important, plan-mandated "TSan clean" gate) — TSan cannot see the ring's memmove copies; ordering is verified by review/disassembly. Fix: document the blind spot in tests + spike docs, and add a release-mode small-ring ordering stress test (capacity 16, chunks 1…4, pure spin, ~10M elements) run via `swift test -c release -Xswiftc -enable-testing --filter …` wired into scripts/test.sh — regression net, not proof — cost if wrong: extra ~seconds of CI.
- Ruling R10: elevate T9 Minor "reset() races consumer → tail>head → write past allocation" to Important (memory safety). Fix in T9: write() computes used = h - t clamped to 0…capacity (never writes beyond free space), init precondition 0 < requested ≤ 1<<62, read() asserts invariant; fill readouts documented producer/consumer-only and clamped — cost if wrong: none.
- Ruling R11: seeks must never call reset() while the render callback may run. SampleRing gains consumer-only `discardReadable()` (tail = head acquired). T10 implements a seek handshake: producer bumps an atomic flush generation and waits (off the RT thread, short sleeps, bounded) for RenderSource to call discardReadable() and ack; when output is not running the producer may call reset() directly — cost if wrong: seek latency up to one render period (~10 ms).
- Ruling R12: fix round 1 scope = Important #1 + minors 2 (split DecodeSession into DecodeSession.swift — a 6th source file, plan deviation for maintainability), 3, 4, 5 (stop() while negotiateRate never returns only), 6 (negotiateRate ≤ 0 → itemFailed(index, "Output rate unavailable"), never fall back to source rate) — cheap now, each expensive later — cost if wrong: one extra file vs plan's five.
- Ruling R13: OutputCapabilities.current stays int32Passthrough:false in Plan 1 regardless of simulator Int32 acceptance — capture measures what pointFlac hands RemoteIO, not what reaches the DAC; simulator = Mac CoreAudio; spec §5.2 accepts a disclosed 24-bit TPDF limit — cost if wrong: 32-bit files dithered to 24 on hardware that might take 32 (inaudible, disclosed, one-line flip after device evidence).
- Ruling R14: RemoteIO capture mode (DEBUG) mutes the actual output after copying, so scripts/test.sh doesn't blast full-scale test noise through the Mac speakers — cost if wrong: none (capture is pre-unit).
- Ruling R15: Player pause = pipeline.stop() + remembered (index, frame); resume = pipeline.start(at: frame) (re-negotiates; keeps client==hardware after route changes while paused); route change while playing restarts pipeline at position — cost if wrong: resume ~20–100 ms instead of instant; pipeline-level pause can come later.
- Ruling R16: take a hardening fix round anyway on minors 1 (enabled gate so no callback starts after stop), 2 (deinit-timeout leaks source+capture too), 4 (expose unit output-scope hardware rate; device-only assert == clientSampleRate; sim S1 hw-side print), 3 (S3 doc/comment overstatement), 5 (S1 wording), nits — device-side races and silent iOS resampling are expensive to find later — cost if wrong: one extra review round.
- Ruling R17: AudioOutput gains hardwareSideSampleRate (default nil); Player sets signal.hardwareRate from it (fallback plan.clientSampleRate); SignalState.indicator shows .resampled(source→hw) when hardwareRate != plan.clientSampleRate — strip never says Pure while iOS resamples after the unit (seen on simulator: hw-side 48000 for client 44100) — cost if wrong: one extra indicator branch. Folded into task-13-rulings.md item 13.
- Ruling R18: accept the same-port route-change refinement (restart only when the port changes) — our own activation/negotiation posts route changes; literal rule risks a restart loop — cost if wrong: a same-named device swap with a different rate keeps the old plan until next start (R17 signal still exposes it as Resampled if hw-side differs).
- Ruling R19: Task 14 adds git-ignored Config/Signing.local.xcconfig (via committed Config/Base.xcconfig `#include?`), scripts/make-ipa.sh (unsigned Release → build/PointFlac.ipa for Sideloadly) and scripts/install-device.sh (Personal Team, devicectl install+launch); no team ID committed — cost if wrong: small scope add to T14.
- Ruling R20: debug track rows use accessibility id trackRow-<file stem> (all fixtures share "Fixture Title" → trackRow-<title> ambiguous) — cost if wrong: none (debug UI).
- Ruling R21: T14 Step 7 manual s32 simulator check → automated UI test (s32-48000 fixture, strip "FLAC · 32-bit · 48 kHz · ● 32→24-bit"); Step 8 device check run by controller with Kiran after commit.
- Ruling R22: DEBUG launch arg -PFMuteOutput installs a RemoteIO capture (mutes speaker); all UI tests pass it — no test noise through Mac speakers.
- Ruling R23: README must NOT say a beta iOS needs the matching Xcode beta — proven false (Xcode 26.6 + Personal Team installed on iOS 27.2); document both Xcode and Sideloadly routes + 7-day/10-app-ID limits — cost if wrong: none.
- Ruling R24: hardware suites (SystemAudioSessionTests, RemoteIOOutputTests) gated by a runtime RemoteIO availability probe via .enabled(if:), never an env switch — so headless CI skips cleanly while Kiran's Mac still runs them.
- Ruling R25: final fix wave = final-fix-wave-brief.md groups A–G (honest strip incl. new indicators .downmixed/.airPlay/.otherRoute/.pending + volume suffix; makeOutput factory; session short-circuits + OSSignposter/Logger; LGPL removal + licence guard + bundled notices; CI tolerance multiplier, TPDF variance/golden, pipeline bit-exact over all fixtures, trackStarted(Int, AudioFormat), underrun counter, TSan stage; CI glob/cancel, install-device Release default, docs wording; NaN guard). Deferred: I5 non-blocking retire + I6 seek overlap (after device measurement, Plan 3 entry gate), Now Playing seek throttle (Plan 3), ImportInbox Plan 2 entry items — cost if wrong: a larger single fix wave.

## Deferred minors (from per-task and final reviews)

- Task 1: minor (deferred): App/Info.plist committed though XcodeGen-generated (decide keep vs ignore in Plan 7)
- Task 1: minor (deferred): AudioFormat.formattedRate one-decimal rule shows 11025 as "11.0 kHz", 22050 as "22.1 kHz" — consider 2 decimals when lossy
- Task 1: minor (deferred): scripts/bootstrap.sh lacks `command -v xcodegen` guard
- Task 1: minor (deferred): empty AppIcon.appiconset may warn in actool — check at first real build
- Task 1: minor (deferred): fix report listed results without raw command output
- Task 2: minor (deferred): make-fixtures.py — no tool precheck/stderr capture on ffmpeg/lame failure; unused `fmt` param in pack(); renamed-mp3 bytes toolchain-dependent (note versions); rmtree(OUT) comment; manifest placeholders for reject fixtures (bits 0 / hasMD5 true / frames 4096) slightly misleading
- Task 3: minor (deferred): config.h has unused FLAC__SYS_DARWIN/OGG_FOUND and redundant largefile defines (harmless)
- Task 3: minor (deferred): CFLACSmokeTests — add withExtendedLifetime(box) around decode calls (apply pattern in Task 6 wrapper)
- Task 3: minor (deferred): Package.swift `-w` unsafeFlags blocks remote consumption — add comment
- Task 3: minor (deferred): encoder sources vendored but unused (~8k lines build time)
- Task 4: minor (deferred): fixed-blocksize frame with 0xFE coded-number lead accepted but libFLAC rejects — treat as badFrameHeader when h[1]&1==0
- Task 4: minor (deferred): metadata type 127 skipped (FLAC spec forbids) and a second STREAMINFO accepted — libFLAC-safe; decide strictness/document
- Task 4: minor (deferred): blockTooLarge guard + `guard let info` are dead (24-bit length < 16 MiB) — add comment
- Task 4: minor (deferred): FileHandleReader.init doesn't close handle on seek failure (closes on dealloc)
- Task 4: minor (deferred): retroactive CustomTestStringConvertible conformance in tests — @retroactive or move into PFTestSupport
- Task 4: minor (deferred): test gaps — exactly-1024-blocks boundary, ID3 prefix past EOF
- Task 5: minor (deferred): no hostile-body unit tests for parseVorbisComment/parsePicture (vendor len > block, count > entries, bad UTF-8, overrun picture lengths, zero-length block)
- Task 5: minor (deferred): Vorbis entry "=x" yields empty key; non-ASCII keys uppercased — skip empty keys
- Task 5: minor (deferred, MUST FIX before Plan 4 ReplayGain): gain parser accepts "nan"/"inf" → add .isFinite guard
- Task 5: minor (deferred): skipsPicturesWhenNotRequested doesn't prove body not read (reader spy)
- Task 6: minor (deferred): ABORTED→.ioError mapping imprecise (libFLAC also ABORTs after >20 unparseable frames in seek, and on MD5 alloc failure)
- Task 6: minor (deferred): test comment says libFLAC reports MISSING_FRAME for corrupt-mid — trace shows it doesn't
- Task 6: minor (deferred): read() drops frames already written in-call when a fatal state appears mid-call
- Task 6: minor (deferred): decodesBitExactly loop never reaches true EOS — add trailing read==0 assertion
- Task 6: minor (deferred): leftover buffer never shrinks after a large gap-padding burst (up to ~7.7 MB at 192k stereo)
- Task 6: minor (deferred): no test for blocksBack > 1 or variable-block-size skip of fallback
- Task 6: minor (deferred): decodeErrorCount rises on each forward decode through damage (consumers must not read it as new damage); finish() doesn't reset positionLost
- Task 7: minor (deferred, relates to T1 minor): kHz shorthand wrong for odd rates (11025→"11.0", 22050→"22.1") — honesty issue; fix formattedRate to ≤3 decimals trimmed + tests for 22.05/11.025/352.8
- Task 7: minor (deferred → CARRY TO T13): SignalStrip.text can be inconsistent if plan/hardwareRate disagree; T13 must set plan + hardwareRate together from the same negotiation (or derive displayed rate from plan.clientSampleRate)
- Task 7: minor (deferred): allStates lacks depthReduced+bluetooth/processing combos
- Task 8: minor (deferred): TPDF shape untested — uniform dither would pass; add histogram/variance test + fixed-seed golden vector
- Task 8: minor (deferred → note for T10): resampler streaming coverage thin (one chunk size, mono only, no chunked-vs-oneshot, no double-flush); chunk-boundary glitch could hide in ±64 tolerance
- Task 8: minor (deferred): SampleRateConverter swallows short-input/alloc/convert errors (returns 0) — surface later
- Task 8: minor (deferred): flush()/process-after-flush unguarded; seed 0 remapped to constant
- Task 9: minor (deferred): head/tail share a cache line (false sharing) — pad if it ever shows in profiles
- Task 9: minor (deferred): staleTail test has redundant `capacity - 0` / `<= capacity` asserts (style)
- Task 10: minor (deferred → CARRY TO T13): seek after queueEnded replays last item without fresh trackStarted and re-emits trackEnded/queueEnded; Player should restart via start() after queueEnded, not seek.
- Task 10: minor (deferred → CARRY TO T13): ack wait + drain depend on render callbacks — pause, interruptions and route changes must go through the pipeline (stop/start), never stop the output behind its back.
- Task 10: minor (deferred): seek during format-change drain/negotiation and start()-replacing-running-queue paths not pinned by tests
- Task 10: minor (deferred): play → first sample < 150 ms not measured on host (Task 12 device/RemoteIO)
- Task 10: minor (deferred → CARRY TO T13): negotiateRate cancellation is cooperative — a late answer's side effect (setPreferredSampleRate) can land after a later start(); Player must serialise negotiation.
- Task 11: minor (deferred → CARRY TO T13): session events stream is unbounded (volume events pile up before Player consumes); Player must read outputVolume once at start (KVO has no initial value); Player must stop output before requestSampleRate (pipeline already does at plan changes).
- Task 12: minor (deferred): AddInstanceForFactory simulator HAL log noise on session activation (pre-existing; note in S1/S3 later)
- Task 12: minor (deferred): renderingEnabled test hook compiled into Release — move under #if DEBUG
- Task 12: minor (deferred): acceptsFloat32Client truncates mSampleRate vs property's .rounded()
- Task 12: minor (deferred): class doc — a stop() that times out (2 s) returns without the no-in-flight guarantee; say so. deinit-timeout still Uninitialize/Dispose under a stuck callback (pre-existing). start() resets firstRealAt/startedAt with two relaxed stores (cosmetic negative latency window).
- Task 13: minor (deferred): SessionGate has no watchdog — a requestSampleRate/activate that never returns leaves later starts in .preparing forever
- Task 13: minor (deferred → device timing T14/final): main actor can stall behind decode-thread RemoteIO configure/start/stop while holding the output-lease lock
- Task 13: minor (deferred → T14 device): first play runs activate() + negotiation through the gate before configure — measure play → first sample on device
- Task 13: minor (deferred → FINAL FIX WAVE, honesty): paused route refresh overwrites R17 hw-side value with session.sampleRate unconditionally → on simulator strip flips .resampled(44.1→48) to Pure while paused; overwrite only when live ≠ settledRate. Also unplug-while-playing pause skips the refresh; .ended doesn't refresh either.
- Task 13: minor (deferred → FINAL FIX WAVE): stale settledRate in .preparing → needless relaunch after activation-caused same-port notification (activate() records no rate); fix: activate() records session.sampleRate or skip rate check until current engine negotiated; doc's "cannot loop" argument should cover activation-caused notifications.
- Task 13: minor (deferred): artwork cache keyed on id only (lazy artwork later would stay cached as none); no through-Player test for a notification while a negotiation holds the gate; Player.currentEngine hook wider than needed.
- Task 14: minor (deferred → Plan 2): ImportInbox.list() re-parses every file's metadata per call — needs an index/cache before libraries grow.
- Task 14: minor (deferred → controller device check): devicectl may consume leading-dash app args (-PFPreloadFixtures) in install-device.sh launch.
- Task 14: minor (deferred): UI tests' "Resampled" branch and "Audio session unavailable" skip never executed locally (Mac at 48 kHz)
- Task 15: minor (deferred → FINAL FIX WAVE): ci.yml Xcode glob can pick beta/RC (exclude *beta*/*Candidate*); iPhone 17 Pro presence check not tied to iOS 26 runtime; cancel-in-progress also cancels main pushes (limit to PRs); probe-failure skip only print-visible (document in README/CI); probe doesn't deactivate session; brew xcodegen unpinned.
