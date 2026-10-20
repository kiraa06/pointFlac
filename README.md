# pointFlac

pointFlac is a native iOS player for hi-res FLAC music, written in Swift 6 and SwiftUI. It decodes with libFLAC and keeps the output at the hardware sample rate, so iOS never resamples behind your back.

Build: `scripts/bootstrap.sh && open PointFlac.xcodeproj`

Test: `scripts/test.sh`

On your own iPhone:

- With Xcode: copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig`, set your team ID in it (a free Personal Team works), connect the phone, and run `scripts/install-device.sh`.
- With Sideloadly: run `scripts/make-ipa.sh` and sideload the unsigned `build/PointFlac.ipa`.
