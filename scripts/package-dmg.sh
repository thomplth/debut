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

echo "Built: $DMG"
