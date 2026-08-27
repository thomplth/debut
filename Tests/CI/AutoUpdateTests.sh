#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
eligibility="$repo_root/scripts/stable-update-eligibility.sh"
appcast="$repo_root/scripts/generate-appcast.sh"
plist="$repo_root/Resources/Info.plist"
package="$repo_root/Package.swift"
build="$repo_root/scripts/build-app.sh"
package_dmg="$repo_root/scripts/package-dmg.sh"
daily="$repo_root/.github/workflows/release-daily.yml"
manual="$repo_root/.github/workflows/release-manual.yml"
publish="$repo_root/.github/workflows/release-publish.yml"
failures=0

fail() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

expect_contains() {
    local path="$1" pattern="$2" message="$3"
    grep -Eq -- "$pattern" "$path" || fail "$message"
}

[[ -x "$eligibility" ]] || fail "missing executable stable-update-eligibility.sh"
[[ -x "$appcast" ]] || fail "missing executable generate-appcast.sh"

if [[ -x "$eligibility" ]]; then
    [[ "$($eligibility stable 1.2.0)" == "eligible=true" ]] \
        || fail "a stable .0 release must be update eligible"
    [[ "$($eligibility daily 1.2.1)" == "eligible=false" ]] \
        || fail "a daily release must not be update eligible"
    if "$eligibility" stable 1.2.1 >/dev/null 2>&1; then
        fail "a patch release must be rejected from the stable channel"
    fi
    if "$eligibility" stable invalid >/dev/null 2>&1; then
        fail "an invalid stable version must be rejected"
    fi
fi

if [[ -x "$appcast" ]]; then
    fixture="$(mktemp -d)"
    touch "$fixture/Debut.dmg" "$fixture/private-key"
    fake_signer="$fixture/sign_update"
    cat > "$fake_signer" <<'SCRIPT'
#!/bin/bash
echo 'sparkle:edSignature="fixture-signature" length="1234"'
SCRIPT
    chmod +x "$fake_signer"
    SPARKLE_SIGN_UPDATE="$fake_signer" GITHUB_REPOSITORY=thomplth/debut \
        "$appcast" 1.2.0 "$fixture/Debut.dmg" "$fixture/private-key" "$fixture/appcast.xml" \
        >/dev/null
    expect_contains "$fixture/appcast.xml" 'releases/download/v1\.2\.0/Debut\.dmg' \
        "the appcast must point at the immutable versioned release asset"
    expect_contains "$fixture/appcast.xml" 'sparkle:edSignature="fixture-signature" length="1234"' \
        "the appcast must carry Sparkle's signature and exact archive length"
    if SPARKLE_SIGN_UPDATE="$fake_signer" "$appcast" 1.2.1 \
        "$fixture/Debut.dmg" "$fixture/private-key" "$fixture/patch.xml" >/dev/null 2>&1; then
        fail "appcast generation must refuse patch releases"
    fi
    rm -rf "$fixture"
fi

expect_contains "$package" 'url: "https://github.com/sparkle-project/Sparkle"' \
    "Package.swift must pin the official Sparkle package"
debut_core_target="$(awk '
    /^[[:space:]]*\.target\($/ { block = $0 ORS; in_block = 1; is_core = 0; next }
    in_block {
        block = block $0 ORS
        if ($0 ~ /name: "DebutCore"/) is_core = 1
        if ($0 ~ /^[[:space:]]*\),$/) {
            if (is_core) { printf "%s", block; exit }
            in_block = 0
        }
    }
' "$package")"
if grep -q 'product(name: "Sparkle"' <<< "$debut_core_target"; then
    fail "DebutCore must not link Sparkle into standalone E2E and benchmark executables"
fi
expect_contains "$plist" '<key>SUFeedURL</key>' "Info.plist must declare the Sparkle feed"
expect_contains "$plist" 'releases/latest/download/appcast.xml' \
    "the app must read the stable GitHub release appcast"
expect_contains "$plist" '<key>SUPublicEDKey</key>' "Info.plist must contain the Sparkle public key"
expect_contains "$plist" 'CtM67t8i60pFgyqC08m0za5aNl8anza7JZv6A93SILA=' \
    "Info.plist must contain the configured Sparkle public key"
expect_contains "$build" 'Contents/Frameworks' "the app bundle must embed Sparkle.framework"
expect_contains "$build" 'Sparkle.framework' "the build must package Sparkle"
expect_contains "$build" -- '--options runtime' "distribution signing must enable Hardened Runtime"
expect_contains "$build" -- '--timestamp' "distribution signing must use a secure timestamp"
expect_contains "$build" 'Installer\.xpc' "Sparkle nested code must be signed explicitly"
expect_contains "$package_dmg" 'codesign.*\$DMG' \
    "stable packaging must sign the outer disk image before notarization"

expect_contains "$daily" 'channel: daily' "daily releases must identify the daily channel"
expect_contains "$manual" 'channel: stable' "manual releases must identify the stable channel"
expect_contains "$publish" "environment:.*(daily-release|stable-release)" \
    "release secrets must be isolated by channel environment"
expect_contains "$publish" 'stable-update-eligibility\.sh' \
    "publishing must enforce stable update eligibility"
expect_contains "$publish" -- '--prerelease' "daily GitHub releases must be prereleases"
expect_contains "$publish" 'notarytool submit' "stable releases must be notarized"
expect_contains "$publish" 'stapler staple' "stable releases must staple the notarization ticket"
expect_contains "$publish" 'generate-appcast\.sh' "stable releases must generate an appcast"
expect_contains "$publish" 'SPARKLE_EDDSA_PRIVATE_KEY' \
    "stable appcasts must be signed with the protected Sparkle key"

if (( failures > 0 )); then
    exit 1
fi

echo "PASS: automatic update contract"
