#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

# Artifact mode must reject a missing bundle, rather than treating it as a cold
# checkout where the source-only checks are enough.
if bash "$repo_root/Tests/CI/PackagingTests.sh" --artifact "$fixture/missing.app" >"$fixture/missing.log" 2>&1; then
    echo "FAIL: missing package passed artifact validation" >&2
    exit 1
fi
grep -q 'no Debut executable' "$fixture/missing.log"

# A plausible bundle with a host binary must fail: /usr/bin/true is universal on
# CI/macOS and cannot satisfy Debut's arm64-only packaged-binary contract.
bundle="$fixture/Debut.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$bundle/Contents/Frameworks"
framework="$bundle/Contents/Frameworks/Sparkle.framework/Versions/B"
mkdir -p "$framework/XPCServices/Downloader.xpc" "$framework/XPCServices/Installer.xpc"
: > "$framework/Sparkle"
cp /usr/bin/true "$bundle/Contents/MacOS/Debut"
cp "$repo_root/Resources/Info.plist" "$bundle/Contents/Info.plist"
cp "$repo_root/Resources/AppIcon.icns" "$bundle/Contents/Resources/AppIcon.icns"
if bash "$repo_root/Tests/CI/PackagingTests.sh" --artifact "$bundle" >"$fixture/malformed.log" 2>&1; then
    echo "FAIL: malformed package passed artifact validation" >&2
    exit 1
fi
grep -q 'arm64 slice' "$fixture/malformed.log"

echo "PASS: packaging artifact rejects missing and malformed bundles"
