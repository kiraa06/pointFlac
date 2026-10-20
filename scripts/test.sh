#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Override the simulator with PF_SIM_NAME, e.g. PF_SIM_NAME="iPhone 17" scripts/test.sh
SIM_NAME="${PF_SIM_NAME:-iPhone 17 Pro}"
DEST="platform=iOS Simulator,name=$SIM_NAME"
echo "Simulator destination: $DEST"

echo "== 1/6 licence guard =="
# Only BSD, MIT, zlib, Apache-2.0 or public-domain code may be vendored, so no file in the libFLAC copy may carry a GPL
# or LGPL notice. Headers wrap the licence's name mid-phrase ("GNU Lesser General Public\n * License"), so the guard
# matches the fragments as well as the full names.
LICENCE_PATTERN='General Public License|Lesser General Public|Library General Public|GNU (Lesser|Library) General'
LICENCE_PATTERN+='|GNU General Public|\b[AL]?GPL(v[0-9])?\b'
if grep -rIlE "$LICENCE_PATTERN" Packages/PointFlacKit/Sources/CFLAC; then
    echo "licence guard: the files above carry a GPL or LGPL notice; remove them from CFLAC" >&2
    exit 1
fi
# The app's bundled notice must carry both licences word for word.
NOTICES=App/ThirdPartyNotices.txt
for licence in Packages/PointFlacKit/Sources/CFLAC/COPYING.Xiph LICENSE; do
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        grep -qF -- "$line" "$NOTICES" || {
            echo "licence guard: $NOTICES lacks this line of $licence: $line" >&2
            exit 1
        }
    done <"$licence"
done
echo "licence guard: clean"

echo "== 2/6 swift format lint =="
swift format lint --strict --recursive App AppUITests Packages

echo "== 3/6 swift test (host) =="
swift test --package-path Packages/PointFlacKit

echo "== 4/6 SampleRing ordering stress (release build) =="
swift test -c release -Xswiftc -enable-testing --package-path Packages/PointFlacKit --filter SampleRingOrderingTests

echo "== 5/6 package tests on simulator =="
(cd Packages/PointFlacKit && xcodebuild test -scheme PointFlacKit-Package -destination "$DEST")

echo "== 6/6 app + UI tests on simulator =="
scripts/bootstrap.sh
xcodebuild test -scheme PointFlac -destination "$DEST"
