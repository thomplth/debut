#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_BUNDLE=".build/Debut.app"
STAGING=".build/dmg-staging"
DMG=".build/Debut.dmg"

./scripts/build-app.sh

echo "Assembling the disk image..."
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/Debut.app"
# The Applications alias is what makes the window a drag-to-install target.
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "Debut" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

if [[ "${DEBUT_DISTRIBUTION_SIGNING:-0}" == "1" ]]; then
    [[ -n "${DEBUT_SIGNING_IDENTITY:-}" ]] || {
        echo "Distribution packaging requires DEBUT_SIGNING_IDENTITY" >&2
        exit 1
    }
    codesign --force --sign "$DEBUT_SIGNING_IDENTITY" --timestamp "$DMG"
    codesign --verify --verbose=2 "$DMG"
fi

echo "Built: $DMG"
