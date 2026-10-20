#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEST='platform=iOS Simulator,name=iPhone 17 Pro'

echo "== 1/6 swift format lint =="
swift format lint --strict --recursive App AppUITests Packages

echo "== 2/6 swift test (host) =="
swift test --package-path Packages/PointFlacKit

echo "== 3/6 SampleRing ordering stress (release build) =="
swift test -c release -Xswiftc -enable-testing --package-path Packages/PointFlacKit --filter SampleRingOrderingTests

echo "== 4/6 package tests on simulator =="
(cd Packages/PointFlacKit && xcodebuild test -scheme PointFlacKit-Package -destination "$DEST")

echo "== 5/6 app + UI tests on simulator =="
scripts/bootstrap.sh
xcodebuild test -scheme PointFlac -destination "$DEST"
