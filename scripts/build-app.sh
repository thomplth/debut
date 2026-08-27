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
FRAMEWORKS="$APP_BUNDLE/Contents/Frameworks"

echo "Building $APP_NAME in release mode..."
cd "$PROJECT_DIR"
# Debut is arm64-only. Without --arch, `swift build` targets whatever host it runs on, so an
# Intel machine or a toolchain running under Rosetta would produce an x86_64 bundle that still
# looks like a valid release.
SWIFT_BUILD=(env TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault /usr/bin/swift build -c release --arch arm64)
"${SWIFT_BUILD[@]}" 2>&1

# --arch puts the product under a triple-specific directory, so ask rather than assume.
BIN_DIR="$("${SWIFT_BUILD[@]}" --show-bin-path)"

echo "Assembling .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS"

cp "$BIN_DIR/Debut" "$MACOS/Debut"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$PROJECT_DIR/Resources/PrivacyInfo.xcprivacy" "$RESOURCES/PrivacyInfo.xcprivacy"

SPARKLE_FRAMEWORK="$BUILD_DIR/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
    echo "Missing resolved Sparkle.framework at $SPARKLE_FRAMEWORK" >&2
    exit 1
fi
# Sparkle.framework is versioned and symlinked. ditto preserves both its links and executable bits.
/usr/bin/ditto "$SPARKLE_FRAMEWORK" "$FRAMEWORKS/Sparkle.framework"

# Generate a simple app icon using sips (theater mask from SF Symbols isn't available as icns,
# so we create a minimal colored icon)
ICON_DIR="$BUILD_DIR/$APP_NAME.iconset"
mkdir -p "$ICON_DIR"
for size in 16 32 64 128 256 512; do
    /usr/bin/sips -z $size $size -s format png /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns --out "$ICON_DIR/icon_${size}x${size}.png" 2>/dev/null || true
done
for size in 32 64 128 256 512 1024; do
    half=$((size / 2))
    /usr/bin/sips -z $size $size -s format png /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns --out "$ICON_DIR/icon_${half}x${half}@2x.png" 2>/dev/null || true
done
iconutil -c icns "$ICON_DIR" -o "$RESOURCES/AppIcon.icns" 2>/dev/null && echo "Icon created." || echo "Icon creation skipped (using system default)."

SIGN_IDENTITY="${DEBUT_SIGNING_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Debut Dev" | head -1 | awk '{print $2}' || true)
fi
if [ -n "$SIGN_IDENTITY" ]; then
    echo "Code signing with identity $SIGN_IDENTITY..."
else
    echo "Code signing (ad-hoc — Accessibility permission will reset on each rebuild)..."
    SIGN_IDENTITY=-
fi

SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [[ "${DEBUT_DISTRIBUTION_SIGNING:-0}" == "1" ]]; then
    [[ "$SIGN_IDENTITY" != "-" ]] || { echo "Distribution signing requires a signing identity" >&2; exit 1; }
    SIGN_ARGS+=(--options runtime --timestamp)
fi

SPARKLE="$FRAMEWORKS/Sparkle.framework/Versions/B"
# Sign from the innermost nested code outward. --deep is intentionally avoided because Sparkle's
# downloader carries its own entitlements and notarization validates every nested signature.
codesign "${SIGN_ARGS[@]}" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
codesign "${SIGN_ARGS[@]}" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Installer.xpc"
codesign "${SIGN_ARGS[@]}" "$SPARKLE/Autoupdate"
codesign "${SIGN_ARGS[@]}" "$SPARKLE/Updater.app"
codesign "${SIGN_ARGS[@]}" "$FRAMEWORKS/Sparkle.framework"
codesign "${SIGN_ARGS[@]}" --entitlements "$PROJECT_DIR/Resources/Debut.entitlements" "$APP_BUNDLE"

codesign --verify --strict --verbose=2 "$APP_BUNDLE"

echo ""
echo "Built: $APP_BUNDLE"
echo "To install: cp -R \"$APP_BUNDLE\" /Applications/"
