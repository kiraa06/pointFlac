#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Override the simulator with PF_SIM_NAME, e.g. PF_SIM_NAME="iPhone 17" scripts/test.sh
SIM_NAME="${PF_SIM_NAME:-iPhone 17 Pro}"
DEST="platform=iOS Simulator,name=$SIM_NAME"
echo "Simulator destination: $DEST"
# Latency-budget tests multiply their budgets by 3 when CI=true (GitHub Actions sets it; see LatencyBudget). xcodebuild
# hands TEST_RUNNER_-prefixed variables to the test process without the prefix, so the simulator stages see it too.
export TEST_RUNNER_CI="${CI:-}"

echo "== 1/7 licence guard =="
# Only BSD, MIT, zlib, Apache-2.0 or public-domain code may be vendored, so no file in the libFLAC or libebur128 copy may carry a GPL
# or LGPL notice. Headers wrap the licence's name mid-phrase ("GNU Lesser General Public\n * License"), so the guard
# matches the fragments as well as the full names.
LICENCE_PATTERN='General Public License|Lesser General Public|Library General Public|GNU (Lesser|Library) General'
LICENCE_PATTERN+='|GNU General Public|\b[AL]?GPL(v[0-9])?\b'
if grep -rIlE "$LICENCE_PATTERN" Packages/PointFlacKit/Sources/CFLAC Packages/PointFlacKit/Sources/CEBUR128; then
    echo "licence guard: the files above carry a GPL or LGPL notice; remove them from CFLAC or CEBUR128" >&2
    exit 1
fi
# The app's bundled notice must carry every vendored licence word for word.
NOTICES=App/ThirdPartyNotices.txt
for licence in Packages/PointFlacKit/Sources/CFLAC/COPYING.Xiph Packages/PointFlacKit/Sources/CEBUR128/COPYING.libebur128 Packages/PointFlacKit/Licenses/LICENSE.bs2b LICENSE; do
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        grep -qF -- "$line" "$NOTICES" || {
            echo "licence guard: $NOTICES lacks this line of $licence: $line" >&2
            exit 1
        }
    done <"$licence"
done
echo "licence guard: clean"

echo "== 2/7 swift format lint =="
swift format lint --strict --recursive App AppUITests Packages

echo "== 3/7 swift test (host) =="
swift test --package-path Packages/PointFlacKit

echo "== 4/7 thread sanitizer: pipeline, player, ring, scrub, sound chain, sound in the pipeline (host) =="
# TSan cannot see the ring's memmove copies (ruling R9), so stage 5 stresses their ordering in a release build.
swift test --sanitize=thread --package-path Packages/PointFlacKit --filter 'PlaybackPipelineTests|PlayerTests|SampleRingTests'
# The scrub suites on their own: their decoder threads would otherwise share the CPU with the pipeline's latency checks.
swift test --sanitize=thread --package-path Packages/PointFlacKit --filter 'ScrubTests|ScrubWindowTests'
# The Sound chain on its own as well: its runner's install and retire protocol, and the limiter and crossfeed it runs.
swift test --sanitize=thread --package-path Packages/PointFlacKit --filter SoundChainTests
# The chain in the render path on its own too: installs from the main actor, the format change's reset on the decode
# thread and a render thread pulling flat out, all on the same runner.
swift test --sanitize=thread --package-path Packages/PointFlacKit --filter SoundPipelineTests

echo "== 5/7 SampleRing ordering stress (release build) =="
swift test -c release -Xswiftc -enable-testing --package-path Packages/PointFlacKit --filter SampleRingOrderingTests

echo "== 6/7 package tests on simulator =="
(cd Packages/PointFlacKit && xcodebuild test -scheme PointFlacKit-Package -destination "$DEST")

echo "== 7/7 app + UI tests on simulator =="
scripts/bootstrap.sh
xcodebuild test -scheme PointFlac -destination "$DEST"
