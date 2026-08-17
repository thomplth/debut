#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build"
OUTPUT_DIR="$BUILD_DIR/glass-lab-builds"
EXECUTABLE="$BUILD_DIR/release/DebutGlassLab"
PLIST_BUDDY=/usr/libexec/PlistBuddy

cd "$PROJECT_DIR"
TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault /usr/bin/swift build -c release --product DebutGlassLab

mkdir -p "$OUTPUT_DIR"
RECIPES="$($EXECUTABLE --list-recipes)"

while IFS= read -r recipe; do
    [ -n "$recipe" ] || continue
    artifact="DebutGlassLab-$recipe"
    app="$OUTPUT_DIR/$artifact.app"
    zip="$OUTPUT_DIR/$artifact.app.zip"
    contents="$app/Contents"

    rm -rf "$app"
    rm -f "$zip"
    mkdir -p "$contents/MacOS" "$contents/Resources"
    cp "$EXECUTABLE" "$contents/MacOS/DebutGlassLab"
    cp "$PROJECT_DIR/Resources/Info.plist" "$contents/Info.plist"
    cp "$PROJECT_DIR/Resources/PrivacyInfo.xcprivacy" "$contents/Resources/PrivacyInfo.xcprivacy"

    "$PLIST_BUDDY" -c "Set :CFBundleExecutable DebutGlassLab" "$contents/Info.plist"
    "$PLIST_BUDDY" -c "Set :CFBundleName $artifact" "$contents/Info.plist"
    "$PLIST_BUDDY" -c "Set :CFBundleDisplayName $artifact" "$contents/Info.plist"
    "$PLIST_BUDDY" -c "Set :CFBundleIdentifier com.thomplth.DebutGlassLab.$recipe" "$contents/Info.plist"
    "$PLIST_BUDDY" -c "Set :LSMinimumSystemVersion 26.0" "$contents/Info.plist"
    "$PLIST_BUDDY" -c "Add :DebutGlassLabRecipe string $recipe" "$contents/Info.plist"

    sign_identity="$(security find-identity -v -p codesigning | awk '/Debut Dev/ { print $2; exit }')"
    if [ -n "$sign_identity" ]; then
        codesign --force --deep --sign "$sign_identity" \
            --entitlements "$PROJECT_DIR/Resources/Debut.entitlements" "$app"
    else
        codesign --force --deep --sign - \
            --entitlements "$PROJECT_DIR/Resources/Debut.entitlements" "$app"
    fi

    /usr/bin/ditto -c -k --keepParent "$app" "$zip"
    echo "Built $artifact.app"
done <<EOF
$RECIPES
EOF

echo "Glass lab builds: $OUTPUT_DIR"
