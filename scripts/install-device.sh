#!/bin/bash
# Builds the Debug app signed with the team in Config/Signing.local.xcconfig, installs it on the first connected
# iPhone or iPad, and launches it (ruling R19).
#
# Usage: scripts/install-device.sh [--build-only | --unsigned] [-- <app launch arguments>]
#   --build-only  build and sign, then stop: no device is needed.
#   --unsigned    build without signing (CODE_SIGNING_ALLOWED=NO), then stop. This checks the build on a machine with no
#                 team; an unsigned app cannot be installed.
#   -- <args>     passed to the app at launch, for example `-- -PFPreloadFixtures` to import the bundled fixtures.
#
# One-time setup: copy Config/Signing.local.xcconfig.example to Config/Signing.local.xcconfig (git-ignored) and set
# DEVELOPMENT_TEAM in it. A free Personal Team works. The device needs Developer Mode on, and on the first install the
# developer profile has to be trusted in Settings > General > VPN & Device Management.

SIGNING=Config/Signing.local.xcconfig
DERIVED=build/DerivedData-device
BUNDLE_ID=io.github.kiraa06.pointflac

fail() {
    echo "install-device: $*" >&2
    exit 1
}

# Fails unless the signing file exists and names a team.
check_signing() {
    [ -f "$SIGNING" ] || fail "no $SIGNING. Copy $SIGNING.example to $SIGNING and set DEVELOPMENT_TEAM to your team ID \
(Xcode > Settings > Accounts)."
    local team
    team=$(sed -n -E 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([^[:space:]]*).*$/\1/p' "$SIGNING" | tail -n 1)
    if [ -z "$team" ] || [ "$team" = YOUR_TEAM_ID ]; then
        fail "set DEVELOPMENT_TEAM in $SIGNING to your team ID (Xcode > Settings > Accounts)."
    fi
}

# Prints "<identifier><tab><name>" for the first paired, reachable, physical iPhone or iPad in a
# `devicectl list devices --json-output` file, or nothing. Reachable means CoreDevice has a transport to it (USB or the
# local network) and does not call its tunnel unavailable.
first_connected_device() {
    /usr/bin/python3 - "$1" <<'PY'
import json, sys

with open(sys.argv[1]) as f:
    devices = json.load(f).get("result", {}).get("devices", [])
for device in devices:
    hardware = device.get("hardwareProperties", {})
    connection = device.get("connectionProperties", {})
    if hardware.get("platform") != "iOS" or hardware.get("reality") != "physical":
        continue
    if connection.get("pairingState") != "paired" or not connection.get("transportType"):
        continue
    if connection.get("tunnelState") == "unavailable":
        continue
    print(device["identifier"] + "\t" + device.get("deviceProperties", {}).get("name", ""))
    break
PY
}

# Sets DEVICE_ID and DEVICE_NAME, or fails.
find_device() {
    local json found
    json=$(mktemp)
    xcrun devicectl list devices --quiet --json-output "$json" >/dev/null || fail "devicectl could not list devices."
    found=$(first_connected_device "$json")
    rm -f "$json"
    [ -n "$found" ] || fail "no iPhone or iPad is connected. Connect it by USB (or have it on the same network once \
paired), unlock it, and run this again."
    DEVICE_ID=${found%%$'\t'*}
    DEVICE_NAME=${found#*$'\t'}
}

main() {
    set -euo pipefail
    cd "$(dirname "${BASH_SOURCE[0]}")/.."

    local mode=install
    local app_arguments=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --build-only) mode=build-only ;;
            --unsigned) mode=unsigned ;;
            --)
                shift
                app_arguments=("$@")
                break
                ;;
            *) fail "unknown option $1. Usage: scripts/install-device.sh [--build-only | --unsigned] [-- <app args>]" ;;
        esac
        shift
    done

    local signing=(-allowProvisioningUpdates)
    if [ "$mode" = unsigned ]; then
        signing=(CODE_SIGNING_ALLOWED=NO)
    else
        check_signing
    fi
    # Before the build, so a missing device fails in seconds rather than after it.
    if [ "$mode" = install ]; then
        find_device
        echo "install-device: found $DEVICE_NAME ($DEVICE_ID)"
    fi

    scripts/bootstrap.sh
    local app="$DERIVED/Build/Products/Debug-iphoneos/PointFlac.app"
    rm -rf "$app"
    xcodebuild build -project PointFlac.xcodeproj -scheme PointFlac -configuration Debug \
        -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" "${signing[@]}" \
        || fail "the Debug build failed; see the xcodebuild output above."
    [ -x "$app/PointFlac" ] || fail "no app at $app after the build."
    if [ "$mode" != install ]; then
        echo "install-device: built $app ($mode); not installing."
        return
    fi

    xcrun devicectl device install app --device "$DEVICE_ID" "$app" \
        || fail "installing on $DEVICE_NAME failed; see the devicectl output above."
    xcrun devicectl device process launch --terminate-existing --device "$DEVICE_ID" "$BUNDLE_ID" \
        ${app_arguments[@]+"${app_arguments[@]}"} \
        || fail "launching on $DEVICE_NAME failed. If the device says the developer is not trusted, trust it in \
Settings > General > VPN & Device Management, then run this again."
    echo "install-device: installed and launched on $DEVICE_NAME."
}

# Sourcing the script defines the functions without running it, so the device picker can be checked on its own.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
