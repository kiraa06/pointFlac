# pointFlac

pointFlac is a native iOS player for hi-res FLAC music, written in Swift 6 and SwiftUI. It decodes with libFLAC and keeps the output at the hardware sample rate, so iOS never resamples behind your back.

Status: audio core (plan 1 of 7).

## Requirements

- Xcode 26.6 or later
- XcodeGen: `brew install xcodegen`

## Build and test

```sh
scripts/bootstrap.sh          # generates PointFlac.xcodeproj
open PointFlac.xcodeproj
scripts/test.sh               # lint, host tests, simulator tests, app and UI tests
```

`scripts/test.sh` runs on the `iPhone 17 Pro` simulator by default. Set `PF_SIM_NAME` to pick another one, for example `PF_SIM_NAME="iPhone 17" scripts/test.sh`.

## On your iPhone

### With Xcode

1. Copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` and set your team ID in it. A free Personal Team works.
2. Enable Developer Mode on the phone (Settings, Privacy & Security, Developer Mode).
3. Connect the phone and run `scripts/install-device.sh`.
4. Trust the developer under Settings, General, VPN & Device Management.

### With Sideloadly

1. Run `scripts/make-ipa.sh`.
2. Sideload the unsigned `build/PointFlac.ipa` with Sideloadly.
3. Trust the profile under Settings, General, VPN & Device Management.

macOS Gatekeeper may block Sideloadly on first launch. Whether to allow it is your call.

### Free Apple ID limits

Installs signed with a free Apple ID expire after 7 days. Re-install, or use Sideloadly's auto-refresh. A free account can also register only ten app IDs per 7 days.

## What you hear

The signal strip says what happens to the audio on the way to the output: "● Pure" when pointFlac passes it on untouched, or what it changed, such as "● Resampled 96→48" or "● 32→24-bit". It makes no claim beyond what it can show.
