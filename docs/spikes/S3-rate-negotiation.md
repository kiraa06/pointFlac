# S3: audio session sample-rate negotiation

Question: when pointFlac asks `AVAudioSession` for a sample rate, does the hardware run at that rate? The sequence
under test is `setActive(false)`, `setPreferredSampleRate`, `setActive(true)`, then read back `sampleRate`
(`SystemAudioSession.requestSampleRate`). The test is `SystemAudioSessionTests.requestedRateIsReadBack`.

## Simulator

iPhone 17 Pro simulator, built-in output (2026-10-20):

```
S3: requested=44100 actual=44100 port=builtIn
S3: requested=48000 actual=48000 port=builtIn
S3: requested=96000 actual=96000 port=builtIn
```

The simulator follows the request exactly, but only in what `AVAudioSession` reports. The RemoteIO unit's hardware
side stays at the Mac output device's rate (48 kHz here), and the simulator resamples after the unit; see
`S1-output-path.md`. It says nothing about real hardware, which may refuse.

## iPhone 17 Pro + EarPods

Pending. The device route works (Xcode 26.6 with a free Personal Team; see `S1-output-path.md`). To run it:

1. Connect the EarPods.
2. Run from `Packages/PointFlacKit`:

   ```
   xcodebuild test -scheme PointFlacKit-Package -destination 'platform=iOS,name=<device name>' \
       -only-testing:PFAudioTests/SystemAudioSessionTests -allowProvisioningUpdates DEVELOPMENT_TEAM=<team id>
   ```

3. Record the `S3:` lines here. Each one says what the hardware gave for 44.1, 48 and 96 kHz requests.
4. Record the strips from the debug-app check in `S1-output-path.md`: they show the same negotiation end to end,
   for 44.1, 48 and 96 kHz files.
5. Repeat steps 2 and 3 with a USB DAC.

## What this means for the pipeline

The preferred sample rate is only a hint. `requestSampleRate` therefore always returns the rate read back from the
session, even if a step of the negotiation throws. The pipeline compares that actual rate with the file's rate and,
when they differ, resamples itself to the hardware rate. iOS is never allowed to resample silently.
