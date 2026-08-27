#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build"
APP_NAME="Debut Space Switch Lab"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "Building $APP_NAME in release mode..."
cd "$PROJECT_DIR"
SWIFT_BUILD=(env TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault /usr/bin/swift build -c release --arch arm64 --product DebutSpaceSwitchLab)
"${SWIFT_BUILD[@]}"
BIN_DIR="$(env TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault /usr/bin/swift build -c release --arch arm64 --show-bin-path)"

echo "Assembling .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BIN_DIR/DebutSpaceSwitchLab" "$MACOS/DebutSpaceSwitchLab"
cp "$PROJECT_DIR/Resources/SpaceSwitchLabInfo.plist" "$CONTENTS/Info.plist"

ICON_DIR="$BUILD_DIR/SpaceSwitchLab.iconset"
rm -rf "$ICON_DIR"
mkdir -p "$ICON_DIR"
SOURCE_ICON="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns"
for size in 16 32 64 128 256 512; do
    /usr/bin/sips -z "$size" "$size" -s format png "$SOURCE_ICON" --out "$ICON_DIR/icon_${size}x${size}.png" >/dev/null
done
for size in 32 64 128 256 512 1024; do
    half=$((size / 2))
    /usr/bin/sips -z "$size" "$size" -s format png "$SOURCE_ICON" --out "$ICON_DIR/icon_${half}x${half}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_DIR" -o "$RESOURCES/AppIcon.icns"

SIGN_IDENTITY="${DEBUT_SIGNING_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Debut Dev" | head -1 | awk '{print $2}' || true)
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "Code signing ad-hoc; Accessibility permission will reset after rebuild."
    SIGN_IDENTITY=-
else
    echo "Code signing with Debut Dev."
fi
codesign --force --sign "$SIGN_IDENTITY" --entitlements "$PROJECT_DIR/Resources/Debut.entitlements" "$APP_BUNDLE"
codesign --verify --strict --verbose=2 "$APP_BUNDLE"

echo "Built: $APP_BUNDLE"
