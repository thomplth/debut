#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

failures=0

fail() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

research_paths=(
    Sources/DebutGlassLab
    Sources/DebutCore/Views/GlassLabCaptureValidator.swift
    Sources/DebutCore/Views/GlassLabRecipe.swift
    Tests/DebutCoreTests/GlassLabRecipeTests.swift
    docs/KHA-422-liquid-glass-lab.md
    scripts/build-glass-lab.sh
    scripts/tart-glass-lab-guest.sh
    scripts/tart-glass-lab.sh
)

for path in "${research_paths[@]}"; do
    [[ ! -e "$path" ]] || fail "research artifact remains in the product repository: $path"
done

if grep -q 'exclude: \["Screenshots"\]' Package.swift; then
    fail "Package.swift excludes a generated screenshot directory that need not exist"
fi

if grep -q 'appendingPathComponent("Screenshots")' Tests/DebutCoreTests/ScreenshotTests.swift; then
    fail "screenshot tests write generated PNGs into the source tree"
fi

if grep -Eq 'No version bumping|No unit-test CI|No notarisation, no distribution' \
    docs/html/10-build-release.html; then
    fail "the build guide still describes superseded release automation"
fi

if grep -Eq '~1,240-line|holds four shell scripts' docs/html/09-verification.html; then
    fail "the verification guide still reports obsolete repository counts"
fi

if grep -q 'Tools/space-probe' Sources/DebutCore/Services/SpaceService.swift; then
    fail "SpaceService points readers to probes that were removed from the repository"
fi

if (( failures > 0 )); then
    exit 1
fi

echo "PASS: repository hygiene contract"
