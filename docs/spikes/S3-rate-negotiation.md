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

Pending. The device run needs an Xcode build that supports the phone's iOS 27.2 beta. To run it: execute the same
test on the device with the EarPods connected and record the `S3:` lines here, then repeat with a USB DAC.

## What this means for the pipeline

The preferred sample rate is only a hint. `requestSampleRate` therefore always returns the rate read back from the
session, even if a step of the negotiation throws. The pipeline compares that actual rate with the file's rate and,
when they differ, resamples itself to the hardware rate. iOS is never allowed to resample silently.
