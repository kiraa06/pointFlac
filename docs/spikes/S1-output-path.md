# S1: output path for bit-exact playback

Question: can pointFlac hand iOS exactly the samples it decoded, for 16-, 24- and 32-bit sources, through a documented
output API? The tests are `RemoteIOOutputTests` (`Packages/PointFlacKit/Tests/PFAudioTests`), and the output is
`RemoteIOOutput` (`Sources/PFAudio/iOS/RemoteIOOutput.swift`).

**Result on the simulator: PASS.** Every capture is byte-identical to the expected client samples, and the output
latency and the end-to-end latency are both well under the 150 ms budget. The debug app's signal strip agrees (see
"The debug app on the simulator"). The device run is pending (see the end).

## API choice: RemoteIO

pointFlac renders into a RemoteIO audio unit, not AVAudioEngine.

- AVAudioEngine's main mixer is Float32-only, so a 32-bit source could never reach the output as Int32.
- RemoteIO takes the client format set on its input scope (bus 0). pointFlac sets interleaved, packed, native-endian
  Float32 or signed Int32, 32 bits per sample, at `plan.clientSampleRate`.
- The pipeline keeps the client rate equal to the session's hardware rate, so nothing in pointFlac's control asks
  RemoteIO to resample.

The render callback is a `@convention(c)` function that takes no locks, makes no allocations and causes no ARC
traffic. It reaches its context, the `RenderSource` and the debug capture through unretained pointers published in
atomics. A Release build was disassembled to check this. The callback calls only `RenderSource.render`, `bzero` and
`clock_gettime_nsec_np`, and `RenderSource.render` calls only `SampleRing.read` and `bzero`. There is no
`swift_retain` or `swift_release`, no allocation, and no lock or Objective-C call.

`CoreAudio.UnsafeMutableAudioBufferListPointer` was dropped from the callback for the same reason. It lives in a
resilient overlay, so using it meant runtime metadata calls and a dynamically sized stack slot on the real-time
thread.

`stop()` does not rely on `AudioOutputUnitStop` being synchronous. Each callback raises an atomic in-flight count on
entry and lowers it on return, and checks an atomic `enabled` flag first. `stop()` works in three steps:

1. It clears the flag.
2. It calls `AudioOutputUnitStop`.
3. It waits, with a 2 s bound and short sleeps, for the in-flight count to reach zero.

When `stop()` returns, no render call is in flight. Any callback that starts later outputs flagged silence and touches
neither the source, the capture nor the latency timestamps. That covers a callback the unit delivers after
`AudioOutputUnitStop` returns.

## How the capture works

In DEBUG builds, `installCapture(byteCapacity:)` preallocates a buffer. The render callback then `memcpy`s into it
only the real frames that `RenderSource.render` reports, never underrun silence. The copy is taken before the unit, so
it is exactly what pointFlac handed RemoteIO.

Capture mode also mutes the speaker: the callback then zeroes the unit's buffer and flags it as silence.

The expected bytes are derived independently from the raw fixture samples:

- Float32: `v / 2^(b−1)`.
- Float32 for 32-bit sources (reduced to 24 bits): `TPDFDither(seed: 0x9E3779B97F4A7C15)` over the whole sequence from
  frame 0, then `v / 2^31`.
- Int32: `v << (32 − b)`.

## Simulator results

iPhone 17 Pro simulator, iOS 26.5 runtime, Xcode 26.6, built-in output (2026-10-20):

```
S1: float32 accepted; client 48000 Hz 32-bit float 2 ch interleaved; hardware 48000 Hz 32-bit float 2 ch non-interleaved
S1: int32 accepted; client 48000 Hz 32-bit sint 2 ch interleaved; hardware 48000 Hz 32-bit float 2 ch non-interleaved
S1: hw-side 48000 for client 44100
S1: hw-side 48000 for client 96000
S1: hw-side 48000 for client 48000
S1: capture s16-48000 client=float32 reduceTo24=false bytes=32768 exact=true hw-side=48000
S1: capture s24-48000 client=float32 reduceTo24=false bytes=32768 exact=true hw-side=48000
S1: capture s32-48000 client=float32 reduceTo24=true bytes=32768 exact=true hw-side=48000
S1: int32 passthrough s32-48000 bytes=32768 exact=true
S1: firstRenderLatency=16.9 ms endToEnd=18.1 ms
```

A run forced onto the 44.1 kHz fixtures was also exact for all four captures (`s16-44100`, `s24-44100`, `s32-44100`
and the `s32-44100` Int32 passthrough). That run's end-to-end figure included a real 48 → 44.1 kHz renegotiation
(21.3 ms and 22.6 ms).

- **Int32 client: accepted.** RemoteIO took the signed Int32 client format and read it back unchanged. Through a
  pipeline built with `OutputCapabilities(int32Passthrough: true)`, the `s32` capture equals the raw samples exactly
  (b = 32, so the shift is 0).
- **Captures per depth, default capabilities:**
  - 16-bit and 24-bit are exact on the Float32 client.
  - 32-bit is exact against the dithered Float32 expectation.
  - Each capture is 4096 stereo frames, 32768 bytes.
- **Latency, over repeated runs:**
  - `firstRenderLatency` (from `start()` to the first callback that delivered real frames) was 11.6–22.4 ms.
  - End to end (from `PlaybackPipeline.start` to the first real frame rendered) was 12.9–23.6 ms. This includes rate
    negotiation, configuring and starting the unit, and the first decode block.
  - Both are far below the 150 ms budget. The simulator's I/O cycle is 480 frames (10 ms at 48 kHz) and accounts for
    most of it.

### What the simulator cannot show

The unit's hardware side (output scope, bus 0) reads 48 kHz Float32 non-interleaved: the Mac's output device. It reads
the same with the session at 44.1, 48 or 96 kHz, even though `AVAudioSession` reports the requested rate (spike S3).
`reportsHardwareSideRate` reproduces this on every run: it requests 44.1, 96 and 48 kHz, configures at each rate the
session gives, and prints the `S1: hw-side` lines above, read from `RemoteIOOutput.hardwareSideSampleRate`. So:

- The simulator converts an Int32 client to Float32 inside the unit. "Int32 accepted" says only that RemoteIO takes the
  format, not that 32 bits reach any output.
- At session rates other than the Mac's, the simulator resamples after the unit. So the check that the hardware-side
  rate equals the client rate (iOS never resamples silently) runs only on a device. It is in `acceptsFloat32Client`,
  `reportsHardwareSideRate` and both capture tests.

## The debug app on the simulator (ruling R21)

The 32-bit check that was to be done by hand in the app is now a UI test, `PlaybackSmokeTests` (`AppUITests`). It
launches the Debug app with `-PFPreloadFixtures`, which imports the fixtures the Debug build bundles, and
`-PFMuteOutput`, which puts `RemoteIOOutput` in capture mode so nothing reaches the speakers. It then taps a track and
reads the strip. The whole real path runs: `ImportInbox`, `Player`, `SystemAudioSession`, `RemoteIOOutput` and
`SystemNowPlaying`.

iPhone 17 Pro simulator, iOS 26.5 runtime, Xcode 26.6, on a Mac whose output device runs at 48 kHz (2026-10-21):

| Fixture     | Signal strip                            |
| ----------- | --------------------------------------- |
| `s24-48000` | `FLAC · 24-bit · 48 kHz · ● Pure`       |
| `s32-48000` | `FLAC · 32-bit · 48 kHz · ● 32→24-bit`  |

Both match the results above:

- The hardware side runs at 48 kHz, so a 48 kHz source plays at its own rate and the strip can say "● Pure".
- A 32-bit source goes to the Float32 client TPDF-reduced to 24 bits, because `OutputCapabilities.current` claims no
  Int32 passthrough (R13). The strip discloses it.

These exact strings were verified at 48 kHz, and the tests assert them whenever the strip shows no resampling. On a
Mac whose output device runs at another rate, 44.1 kHz say, the hardware side reads that rate and iOS resamples after
the unit. The strip then honestly reads "● Resampled 48→44.1" for both fixtures: resampling outranks the depth
reduction in `SignalState.indicator`. The tests accept that, and on any Mac they still check the source-derived
part: the `FLAC · 24-bit · ` or `FLAC · 32-bit · ` prefix, the "●" indicator, and no "bit-perfect". On a machine with
no usable audio output (a headless CI runner), the two playback tests skip.

## Ruling R13: `OutputCapabilities.current` stays `int32Passthrough: false`

Plan 1 keeps `current` at `false` despite the simulator accepting Int32:

- The capture proves what pointFlac hands the RemoteIO unit, not what iOS passes to the DAC.
- The simulator runs on the Mac's CoreAudio, not on iPhone hardware, and its hardware side is Float32 anyway.

So 32-bit sources are TPDF-dithered to 24 bits on the Float32 client, and the signal strip says so. Spec §5.2 accepts
this as a disclosed limit: the 24-bit TPDF quantisation noise (about −144 dBFS) is below any DAC's noise floor.

If this is wrong, the cost is that 32-bit files get 24-bit TPDF on hardware that might take 32-bit. That is inaudible,
honestly disclosed, and fixed later by flipping one line. `current` flips only on the device evidence below.

## Device runs: pending

The device route works: Xcode 26.6 with a free Personal Team installs on the iPhone 17 Pro running iOS 27.2. For the
team, create `Config/Signing.local.xcconfig` from `Config/Signing.local.xcconfig.example` (git-ignored, never
committed).

### The debug app on the iPhone 17 Pro with EarPods

The fixtures last 85 ms, which is enough to read the strip. Use a real, longer FLAC for the unplug and lock-screen
checks.

1. Plug the EarPods in and set the system volume to 100%.
2. From the repository root, run `scripts/install-device.sh -- -PFPreloadFixtures`. It builds Debug, installs, and
   launches the app with the bundled fixtures imported.
3. Tap each track and record the strip. Expected results:
   - `s16-44100`: `FLAC · 16-bit · 44.1 kHz · ● Pure`. If it reads "● Resampled 44.1→48", the route runs only at
     48 kHz. Record that as a finding, not a bug.
   - `s24-48000`: `FLAC · 24-bit · 48 kHz · ● Pure`.
   - `s32-48000`: `FLAC · 32-bit · 48 kHz · ● 32→24-bit`.
4. `s24-96000` is not bundled. Copy `Packages/PointFlacKit/Sources/PFTestSupport/Resources/Fixtures/s24-96000.flac`
   to the phone (AirDrop to Files, or iCloud Drive), add it with the Add button, and tap it. Expected:
   `FLAC · 24-bit · 48 kHz · ● Resampled 96→48`.
5. Add a real FLAC of a few minutes and play it. Unplug the EarPods: playback must pause, and must not carry on
   through the speaker. Plug them back in and resume.
6. Play it again and lock the phone. The lock screen must show the title and artist, and play/pause must work. Use
   Play All with two or more real tracks to check next and previous.
7. Record the results here and in `S3-rate-negotiation.md`.

### iPhone 17 Pro with EarPods (24-bit/48 kHz cap)

1. Plug the EarPods in and set the system volume to 100%. At this stage the run checks captures, rate behaviour and
   latency on real hardware, not what reaches the DAC.
2. Run from `Packages/PointFlacKit`:

   ```
   xcodebuild test -scheme PointFlacKit-Package -destination 'platform=iOS,name=<device name>' \
       -only-testing:PFAudioTests/RemoteIOOutputTests -allowProvisioningUpdates DEVELOPMENT_TEAM=<team id>
   ```

3. Record every `S1:` line here. Expected results:
   - Float32 accepted, with the hardware rate equal to the client rate. The device-only expectation in
     `acceptsFloat32Client` checks this.
   - The `S1: hw-side <rate> for client <rate>` lines from `reportsHardwareSideRate`, **especially at 44.1 kHz**. The
     hardware side must read 44100 for client 44100. If it reads 48000, iOS resamples after the unit on that route,
     so 44.1 kHz files are not untouched there. The device-only expectation fails, and the finding goes here.
   - Exact captures at 48 kHz, or at 44.1 kHz if the route runs there. The tests pick the matching fixtures.
   - `firstRenderUnder150ms` passing.
   - Whether Int32 is accepted on a device. Also record the hardware-side format line, which shows whether the unit
     converts to Float32 before the route.
4. Repeat with the built-in speaker. Its rate may be fixed. Then the capture tests fail with "the hardware did not take
   … Hz", which is a finding to record, not a bug.

### 32-bit-capable USB DAC: the evidence that would flip `current`

A capture alone can never justify the flip, because it stops at the unit. What would justify it is a bit test at the
DAC:

1. Connect the DAC (USB-C). Set the system volume to 100%: digital volume scaling breaks bit-exactness. Make sure no
   EQ or accessibility audio processing is on.
2. Rerun the command above and record the `S1:` lines, especially "int32 accepted" and the `s32` passthrough capture.
3. Play a 32-bit test file through a pointFlac build with `int32Passthrough: true`. The file's low 8 bits must carry a
   known pattern. `s32-48000` qualifies: its right channel walks every bit and its left channel is 32-bit LCG noise.
   For a long enough recording, use a longer file from the same `signal()` in `scripts/make-fixtures.py`. Verify what
   arrives with one of:
   - **Loopback:** a DAC or interface with a digital output (S/PDIF or AES) feeding a recorder that captures 32-bit
     integer, such as a Mac with a digital input. Compare the recording with the source after aligning the start. All
     32 bits must match, with no dither in the low byte.
   - **DAC bit test:** a DAC with a built-in bit-perfect or bit-depth check, such as a signature-pattern test or an
     input-depth display. It must report 32-bit and pass the test file unchanged.
4. Only if all 32 bits arrive intact, on that route and at unity volume, flip `OutputCapabilities.current` to
   `int32Passthrough: true`. Record the DAC, the route, the iOS version and the method here, and update the
   strip copy. If the low byte arrives truncated, dithered or rescaled, `current` stays `false`, and the disclosed
   24-bit TPDF path stands.
