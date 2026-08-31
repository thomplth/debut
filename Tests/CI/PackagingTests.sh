#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
failures=0

fail() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

expect_equal() {
    local actual="$1"
    local expected="$2"
    local message="$3"
    if [[ "$actual" != "$expected" ]]; then
        fail "$message (expected '$expected', got '$actual')"
    fi
}

# The deployment target is declared twice — once for the compiler, once for Launch Services — and
# only the compiler's copy is enforced by anything. A plist that claims a lower floor than the
# package builds against installs happily on a system the binary cannot run on, so the failure
# lands on the user as a crash at launch rather than on us as a build error. Derive the expected
# value rather than hard-coding it, so bumping the package platform cannot leave the plist behind.
package_platform="$(sed -nE 's/.*\.macOS\(\.v([0-9]+)\).*/\1/p' "$repo_root/Package.swift" | head -1)"
[[ -n "$package_platform" ]] || fail "could not read the macOS platform from Package.swift"

plist_minimum="$(grep -A1 "<key>LSMinimumSystemVersion</key>" "$repo_root/Resources/Info.plist" \
    | sed -nE 's/.*<string>([^<]*)<\/string>.*/\1/p')"
expect_equal "$plist_minimum" "$package_platform.0" \
    "LSMinimumSystemVersion must match the platform Package.swift builds against"

# Debut is arm64-only by intent, not just by accident of the machine that happens to build it.
# `swift build` targets the host, so an Intel host — or an arm64 host running the toolchain under
# Rosetta — would silently produce an x86_64 bundle that no gate would catch.
grep -q -- "--arch arm64" "$repo_root/scripts/build-app.sh" \
    || fail "build-app.sh must pin the architecture to arm64 rather than inheriting the host's"

# If a bundle is lying around from a local build, hold it to the same rule.
binary="$repo_root/.build/Debut.app/Contents/MacOS/Debut"
if [[ -f "$binary" ]]; then
    archs="$(lipo -archs "$binary" 2>/dev/null || true)"
    expect_equal "$archs" "arm64" "the built binary must contain only the arm64 slice"
fi

# The bundle shipped the generic macOS application icon: build-app.sh rasterized
# GenericApplicationIcon.icns behind `|| true`, and Info.plist named no icon at all. Both halves
# failed silently, and a wrong icon reads as a design choice rather than a build fault, so nothing
# surfaced it. The icon is therefore a committed artifact the build copies — the hosted runners
# install no librsvg, so rasterizing the SVG at build time would fail every CI run.
# A missing key makes grep exit non-zero, which under `set -o pipefail` would abort this script
# before it could report anything — the absence has to reach the check below as an empty string.
icon_file="$(grep -A1 "<key>CFBundleIconFile</key>" "$repo_root/Resources/Info.plist" \
    | sed -nE 's/.*<string>([^<]*)<\/string>.*/\1/p' || true)"
if [[ -z "$icon_file" ]]; then
    fail "Info.plist must declare CFBundleIconFile, or macOS falls back to a generic icon"
else
    icns="$repo_root/Resources/$icon_file.icns"
    if [[ ! -f "$icns" ]]; then
        fail "CFBundleIconFile names '$icon_file' but Resources/$icon_file.icns is not committed"
    else
        # An icns missing its large representations still installs, and only looks wrong at the
        # sizes Finder and the About window actually use.
        extracted="$(mktemp -d)"
        if iconutil -c iconset "$icns" -o "$extracted/out.iconset" 2>/dev/null; then
            [[ -f "$extracted/out.iconset/icon_512x512@2x.png" ]] \
                || fail "Resources/$icon_file.icns has no 1024px representation"
            [[ -f "$extracted/out.iconset/icon_16x16.png" ]] \
                || fail "Resources/$icon_file.icns has no 16px representation"
        else
            fail "Resources/$icon_file.icns is not a readable icon set"
        fi
        rm -rf "$extracted"
    fi
fi

! grep -q "GenericApplicationIcon" "$repo_root/scripts/build-app.sh" \
    || fail "build-app.sh must ship Debut's own icon rather than the generic system one"

# The icon in a local bundle has to be the one under review, not a stale artifact.
built_icon="$repo_root/.build/Debut.app/Contents/Resources/AppIcon.icns"
if [[ -f "$built_icon" && -n "$icon_file" && -f "$repo_root/Resources/$icon_file.icns" ]]; then
    cmp -s "$built_icon" "$repo_root/Resources/$icon_file.icns" \
        || fail "the built bundle's icon differs from Resources/$icon_file.icns"
fi

if (( failures > 0 )); then
    exit 1
fi

echo "PASS: packaging contract"
