#!/bin/bash
# Builds an unsigned Release PointFlac.app for iOS devices and packs it as build/PointFlac.ipa, for Sideloadly, which
# re-signs it with the user's own Apple ID (ruling R19). Needs no team and no device.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=build
DERIVED="$BUILD/DerivedData-ipa"
APP="$DERIVED/Build/Products/Release-iphoneos/PointFlac.app"
IPA="$BUILD/PointFlac.ipa"

fail() {
    echo "make-ipa: $*" >&2
    exit 1
}

scripts/bootstrap.sh
mkdir -p "$BUILD"
rm -rf "$APP"
xcodebuild build -project PointFlac.xcodeproj -scheme PointFlac -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO \
    || fail "the Release build failed; see the xcodebuild output above"

[ -x "$APP/PointFlac" ] || fail "no app at $APP after the build"
# The libFLAC BSD-3 notice must ship with every binary build, Release included.
[ -s "$APP/ThirdPartyNotices.txt" ] || fail "the Release app lacks ThirdPartyNotices.txt (the libFLAC licence notice)"
# Ruling R4: Release builds never carry the debug fixtures.
if [ -n "$(find "$APP" -iname '*.flac' -print -quit)" ]; then
    fail "the Release app contains .flac files; the debug fixtures must be excluded from Release"
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
rm -f "$IPA"
# -y keeps symlinks as links, as an .ipa needs.
OUT="$PWD/$IPA"
(cd "$STAGE" && zip -qry "$OUT" Payload) || fail "could not write $IPA"

echo "make-ipa: wrote $IPA (unsigned; Sideloadly signs it)"
