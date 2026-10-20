#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Override the simulator with PF_SIM_NAME, e.g. PF_SIM_NAME="iPhone 17" scripts/test.sh
SIM_NAME="${PF_SIM_NAME:-iPhone 17 Pro}"
DEST="platform=iOS Simulator,name=$SIM_NAME"
echo "Simulator destination: $DEST"

echo "== 1/5 swift format lint =="
swift format lint --strict --recursive App AppUITests Packages

echo "== 2/5 swift test (host) =="
swift test --package-path Packages/PointFlacKit

echo "== 3/5 SampleRing ordering stress (release build) =="
swift test -c release -Xswiftc -enable-testing --package-path Packages/PointFlacKit --filter SampleRingOrderingTests

echo "== 4/5 package tests on simulator =="
(cd Packages/PointFlacKit && xcodebuild test -scheme PointFlacKit-Package -destination "$DEST")

echo "== 5/5 app + UI tests on simulator =="
scripts/bootstrap.sh
xcodebuild test -scheme PointFlac -destination "$DEST"
