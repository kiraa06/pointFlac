#!/bin/bash
# Generates the Debug-only demo library: five small albums of digital silence, tagged, in four formats, so the shelf,
# the crate, the deck's sides and the tonearm have something real to work with in the simulator and in UI tests.
# Silence keeps each file small (large FLAC blocks of constant subframes) and plays nothing aloud. Needs ffmpeg.
# Idempotent: it rewrites App/Debug/Fixtures/demo-*.flac. Ruling R4 applies: Release builds drop the folder.
set -euo pipefail
cd "$(dirname "$0")/Fixtures"
rm -f demo-*.flac

# album-slug|album|artist|rate|bits|track:seconds,...
ALBUMS=(
    "night-drive|Night Drive|Lumen Arcade|96000|24|Ignition:190,Neon Mile:245,Overpass:170,Tail Lights:320,Last Exit:220"
    "paper-moons|Paper Moons|Ada Vale|44100|16|Fold:150,Crease:205,Origami Sky:260,Unfold:185"
    "hydrophone|Hydrophone|The Tidelines|96000|32|Sonar:280,Kelp Forest:340,Abyssal:410"
    "copper-garden|Copper Garden|Mira Sol|48000|24|Verdigris:200,Patina:175,Rootbound:230,Bloom:195"
    "low-orbit|Low Orbit|Kessler Quartet|88200|24|Perigee:300,Apogee:330"
)

for entry in "${ALBUMS[@]}"; do
    IFS='|' read -r slug album artist rate bits tracks <<<"$entry"
    n=0
    IFS=',' read -ra list <<<"$tracks"
    for t in "${list[@]}"; do
        n=$((n + 1))
        title="${t%%:*}"
        seconds="${t##*:}"
        fmt=s32
        [ "$bits" = 16 ] && fmt=s16
        ffmpeg -hide_banner -loglevel error -y -f lavfi -i "anullsrc=r=${rate}:cl=stereo" -t "$seconds" \
            -sample_fmt "$fmt" -bits_per_raw_sample "$bits" -c:a flac -strict experimental -frame_size 16384 \
            -metadata title="$title" -metadata artist="$artist" -metadata album="$album" \
            -metadata tracknumber="$n" -metadata date=2026 \
            "$(printf 'demo-%s-%02d.flac' "$slug" "$n")"
    done
done
ls -la demo-*.flac | awk '{ s += $5 } END { print NR " files, " s " bytes" }'
