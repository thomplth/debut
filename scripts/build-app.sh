#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build"
APP_NAME="Debut"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "Building $APP_NAME in release mode..."
cd "$PROJECT_DIR"
TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault /usr/bin/swift build -c release 2>&1

echo "Assembling .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BUILD_DIR/release/Debut" "$MACOS/Debut"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"

# Generate a simple app icon using sips (theater mask from SF Symbols isn't available as icns,
# so we create a minimal colored icon)
ICON_DIR="$BUILD_DIR/Debut.iconset"
mkdir -p "$ICON_DIR"
for size in 16 32 64 128 256 512; do
    /usr/bin/sips -z $size $size -s format png /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns --out "$ICON_DIR/icon_${size}x${size}.png" 2>/dev/null || true
done
for size in 32 64 128 256 512 1024; do
    half=$((size / 2))
    /usr/bin/sips -z $size $size -s format png /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns --out "$ICON_DIR/icon_${half}x${half}@2x.png" 2>/dev/null || true
done
iconutil -c icns "$ICON_DIR" -o "$RESOURCES/AppIcon.icns" 2>/dev/null && echo "Icon created." || echo "Icon creation skipped (using system default)."

SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Debut Dev" | head -1 | awk '{print $2}')
if [ -n "$SIGN_IDENTITY" ]; then
    echo "Code signing with 'Debut Dev' certificate ($SIGN_IDENTITY)..."
    codesign --force --deep --sign "$SIGN_IDENTITY" --entitlements "$PROJECT_DIR/Resources/Debut.entitlements" "$APP_BUNDLE"
else
    echo "Code signing (ad-hoc — Accessibility permission will reset on each rebuild)..."
    codesign --force --deep --sign - --entitlements "$PROJECT_DIR/Resources/Debut.entitlements" "$APP_BUNDLE"
fi

echo ""
echo "Built: $APP_BUNDLE"
echo "To install: cp -R \"$APP_BUNDLE\" /Applications/"
