#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEST='platform=iOS Simulator,name=iPhone 17 Pro'

echo "== 1/4 swift format lint =="
swift format lint --strict --recursive App Packages

echo "== 2/4 swift test (host) =="
swift test --package-path Packages/PointFlacKit

echo "== 3/4 package tests on simulator =="
(cd Packages/PointFlacKit && xcodebuild test -scheme PointFlacKit-Package -destination "$DEST")

echo "== 4/4 app + UI tests on simulator =="
scripts/bootstrap.sh
xcodebuild test -scheme PointFlac -destination "$DEST"
