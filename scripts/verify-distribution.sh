#!/bin/bash
set -euo pipefail
# Read-only Gatekeeper assessment. Launch/update UI is exercised only in Tart.
dmg="${1:?usage: verify-distribution.sh <dmg> <short-version> <build-version>}"
version="${2:?missing short version}"
build="${3:?missing bundle build}"
mount="$(mktemp -d)"
mounted=false
cleanup() {
    if [[ "$mounted" == true ]]; then hdiutil detach "$mount" -quiet || true; fi
    rmdir "$mount" || true
}
trap cleanup EXIT
xcrun stapler validate "$dmg"
spctl -a -t open -vv --context context:primary-signature "$dmg"
hdiutil attach "$dmg" -readonly -nobrowse -mountpoint "$mount" -quiet
mounted=true
app="$mount/Debut.app"
codesign --verify --deep --strict --verbose=2 "$app"
spctl -a -t exec -vv "$app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$version" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" == "$build" ]]
if [[ -n "${4:-}" ]]; then
    TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault /usr/bin/swift "$(dirname "$0")/verify-appcast-signature.swift" "$4" "$dmg" "$app/Contents/Info.plist"
fi
echo "PASS: notarized disk image and packaged application pass Gatekeeper ($version, build $build)"
