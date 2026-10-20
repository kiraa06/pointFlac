# pointFlac

pointFlac is a native iOS player for hi-res FLAC music, written in Swift 6 and SwiftUI. It decodes with libFLAC, asks the hardware for each file's sample rate and plays at the rate the hardware runs at, resampling itself when the two differ. Its signal strip shows whenever anything changes the audio, whether pointFlac, iOS or the route does it.

Status: audio core (plan 1 of 7).

## Requirements

- macOS 26, to run the host tests (`swift test`)
- Xcode 26.6 or later
- The iOS 26 simulator runtime (Xcode → Settings → Components)
- XcodeGen: `brew install xcodegen`

## Build and test

```sh
scripts/bootstrap.sh          # generates PointFlac.xcodeproj
open PointFlac.xcodeproj
scripts/test.sh               # licence guard, lint, host tests, thread sanitizer, simulator tests, app and UI tests
```

`scripts/test.sh` runs on the `iPhone 17 Pro` simulator by default. Set `PF_SIM_NAME` to pick another one, for example `PF_SIM_NAME="iPhone 17" scripts/test.sh`.

The latency tests hold the spec's budgets (a 50 ms seek, a 150 ms first frame) on your Mac and three times those under CI (`CI=true`), since shared runners are noisy. On a machine with no usable audio output, such as a headless runner, the suites that need the real audio hardware and the playback UI tests skip, and the test log says why.

## On your iPhone

### With Xcode

1. Copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` and set your team ID in it. A free Personal Team works.
2. Enable Developer Mode on the phone (Settings, Privacy & Security, Developer Mode).
3. Connect the phone and run `scripts/install-device.sh`.
4. Trust the developer under Settings, General, VPN & Device Management.

`scripts/install-device.sh` builds Release by default, so the audio path runs optimised and without the debug fixtures. Pass `--debug` for a Debug build, which the debug launch flags need. For example, `scripts/install-device.sh --debug -- -PFPreloadFixtures` imports the bundled test fixtures on launch. `--build-only` and `--unsigned` build without installing.

### With Sideloadly

1. Run `scripts/make-ipa.sh`.
2. Sideload the unsigned `build/PointFlac.ipa` with Sideloadly.
3. Trust the profile under Settings, General, VPN & Device Management.

macOS Gatekeeper may block Sideloadly on first launch. Whether to allow it is your call.

### Free Apple ID limits

Installs signed with a free Apple ID expire after 7 days. Re-install, or use Sideloadly's auto-refresh. A free account can also register only ten app IDs per 7 days.

## What you hear

The signal strip says what happens to the audio on the way to the output. It reads "● Pure" only when pointFlac passes the audio on untouched, at the hardware's rate, on a route that doesn't alter it. Otherwise it says what changes the audio, such as "● Resampled 96→48", "● 32→24-bit", "● Bluetooth (lossy)", "● AirPlay (re-encoded)" or "● Downmixed 2→1". It reads "● Starting…" until the path is known. On a USB DAC below full system volume it adds "● Volume 80%". It makes no claim beyond what it can show.

## Licences

pointFlac is MIT-licensed. It includes libFLAC under its BSD licence: see [docs/third-party.md](docs/third-party.md). The app shows both licences under Licences.
