# S1: output path for bit-exact playback

Question: can pointFlac hand iOS exactly the samples it decoded, for 16-, 24- and 32-bit sources, through a documented
output API? The tests are `RemoteIOOutputTests` (`Packages/PointFlacKit/Tests/PFAudioTests`), and the output is
`RemoteIOOutput` (`Sources/PFAudio/iOS/RemoteIOOutput.swift`).

**Result on the simulator: PASS.** Every capture is byte-identical to the expected client samples, and the output
latency and the end-to-end latency are both well under the 150 ms budget. The device run is pending (see the end).

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

`stop()` returns only once no render call is in flight. It does not rely on `AudioOutputUnitStop` being synchronous.
Instead it waits, with a 2 s bound and short sleeps, on an atomic in-flight count that the callback raises on entry and
lowers on return.

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
S1: capture s16-48000 client=float32 reduceTo24=false bytes=32768 exact=true
S1: capture s24-48000 client=float32 reduceTo24=false bytes=32768 exact=true
S1: capture s32-48000 client=float32 reduceTo24=true bytes=32768 exact=true
S1: int32 passthrough s32-48000 bytes=32768 exact=true
S1: firstRenderLatency=22.4 ms endToEnd=23.6 ms
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
So:

- The simulator converts an Int32 client to Float32 inside the unit. "Int32 accepted" says only that RemoteIO takes the
  format, not that 32 bits reach any output.
- At session rates other than the Mac's, the simulator resamples internally. `acceptsFloat32Client` therefore checks
  hardware rate == client rate only on a device.

## Ruling R13: `OutputCapabilities.current` stays `int32Passthrough: false`

Plan 1 keeps `current` at `false` despite the simulator accepting Int32:

- The capture proves what pointFlac hands the RemoteIO unit, not what iOS passes to the DAC.
- The simulator runs on the Mac's CoreAudio, not on iPhone hardware, and its hardware side is Float32 anyway.

So 32-bit sources are TPDF-dithered to 24 bits on the Float32 client, and the signal strip says so. Spec §5.2 accepts
this as a disclosed limit: 24 significant bits is far below any DAC's noise floor.

If this is wrong, the cost is that 32-bit files get 24-bit TPDF on hardware that might take 32-bit. That is inaudible,
honestly disclosed, and fixed later by flipping one line. `current` flips only on the device evidence below.

## Device runs: pending

The device run needs an Xcode build that supports the iPhone 17 Pro's iOS 27.2 beta (as for S3).

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
