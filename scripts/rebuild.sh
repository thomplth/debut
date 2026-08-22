#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Building..."
build_log="$(mktemp)"
./scripts/build-app.sh | tee "$build_log"
app_bundle="$(awk '/^Built: /{ sub(/^Built: /, ""); print }' "$build_log")"
rm -f "$build_log"
if [[ -z "$app_bundle" || ! -d "$app_bundle" ]]; then
    echo "build-app.sh did not report a built app bundle." >&2
    exit 1
fi
# Taking the name from the build rather than repeating it here keeps a rename from making this
# script delete and relaunch some other app that happens to be called Debut.
installed="/Applications/$(basename "$app_bundle")"

pkill -f "$installed" 2>/dev/null || true
sleep 1

echo "Installing..."
rm -rf "$installed"
cp -R "$app_bundle" "$installed"

echo "Launching..."
open "$installed"
sleep 3
