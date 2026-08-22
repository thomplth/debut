#!/bin/bash
set -euo pipefail

# Renaming the app bundle broke E2E silently: the host staged a path that no longer existed,
# the guest granted Accessibility to a bundle ID nothing published, and DebutE2E read a
# diagnostic.json in a directory the app had stopped writing to. Nothing here can be checked
# by a unit test, so the contract is that the name, the bundle ID and the support directory
# are each derived from one source rather than spelled out again.

cd "$(dirname "$0")/../.."

failures=0

fail() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

expect_contains() {
    grep -Eq -- "$2" "$1" || fail "$3"
}

expect_not_contains() {
    if grep -Eq -- "$2" "$1"; then
        fail "$3"
    fi
}

# Only DebutCore may name the support directory; everything else asks it.
support_offenders="$(grep -rln 'for: \.applicationSupportDirectory' Sources/ \
    | grep -v '^Sources/DebutCore/DebutCore.swift$' || true)"
if [[ -n "$support_offenders" ]]; then
    fail "these build their own Application Support path instead of using DebutCore.applicationSupportDirectory:
$support_offenders"
fi
expect_contains "Sources/DebutCore/DebutCore.swift" 'applicationSupportDirectory' \
    "DebutCore must publish the Application Support directory"

# The host stages whatever build-app.sh produced, rather than a second copy of its name.
expect_not_contains "scripts/tart-e2e.sh" '\.build/[A-Za-z-]+\.app' \
    "Tart E2E must not hardcode the app bundle name the build script chose"

# The guest reads the name and the bundle ID out of the artifact it was handed.
expect_not_contains "scripts/tart-e2e-guest.sh" '/Applications/[A-Za-z-]+\.app' \
    "the guest must derive the installed app path from the staged archive"
expect_not_contains "scripts/tart-e2e-guest.sh" 'com\.thomplth\.[A-Za-z]+' \
    "the guest must read the bundle ID out of the installed app, not repeat it"
expect_contains "scripts/tart-e2e-guest.sh" 'CFBundleIdentifier' \
    "the guest must read CFBundleIdentifier to target its TCC grants"

# The guest has no other way to find the state it must clear between runs, so it takes the
# last component of the bundle ID. That is only sound while the two actually agree.
bundle_id="$(/usr/bin/awk '/<key>CFBundleIdentifier<\/key>/ { getline; gsub(/.*<string>|<\/string>.*/, ""); print }' Resources/Info.plist)"
support_name="$(/usr/bin/awk -F'"' '/appendingPathComponent\(".*"\)/ { print $2 }' Sources/DebutCore/DebutCore.swift)"
if [[ "${bundle_id##*.}" != "$support_name" ]]; then
    fail "bundle ID '$bundle_id' and support directory '$support_name' disagree; the guest derives one from the other"
fi

if (( failures > 0 )); then
    exit 1
fi

echo "PASS: app identity contract"
