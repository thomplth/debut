#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
eligibility="$repo_root/scripts/update-eligibility.sh"
appcast="$repo_root/scripts/generate-appcast.sh"
apply_version="$repo_root/scripts/apply-version.sh"
plist="$repo_root/Resources/Info.plist"
package="$repo_root/Package.swift"
build="$repo_root/scripts/build-app.sh"
package_dmg="$repo_root/scripts/package-dmg.sh"
nightly="$repo_root/.github/workflows/release-nightly.yml"
manual="$repo_root/.github/workflows/release-manual.yml"
publish="$repo_root/.github/workflows/release-publish.yml"
validate_credentials="$repo_root/scripts/validate-release-credentials.sh"
# The stable wrapper and direct nightly job execute one shared composite action.
publish_contract="$(mktemp)"
trap 'rm -f "$publish_contract"' EXIT
cat "$publish" "$(dirname "$publish")/../actions/publish-release/action.yml" > "$publish_contract"
failures=0

fail() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

expect_contains() {
    local path="$1" pattern="$2" message="$3"
    grep -Eq -- "$pattern" "$path" || fail "$message"
}

[[ -x "$eligibility" ]] || fail "missing executable update-eligibility.sh"
[[ -x "$appcast" ]] || fail "missing executable generate-appcast.sh"
[[ -x "$validate_credentials" ]] || fail "missing executable validate-release-credentials.sh"

if [[ -x "$eligibility" ]]; then
    [[ "$($eligibility stable 1.2.0)" == "eligible=true" ]] \
        || fail "a stable .0 release must be update eligible"
    [[ "$($eligibility nightly 1.3.0-nightly.20260908)" == "eligible=true" ]] \
        || fail "a nightly release must be eligible for its own update channel"
    if ! "$eligibility" stable 1.2.1 >/dev/null 2>&1; then
        fail "a promoted patch release must be accepted"
    fi
    if "$eligibility" stable invalid >/dev/null 2>&1; then
        fail "an invalid stable version must be rejected"
    fi
    if "$eligibility" stable 1.3.0-nightly.20260908 >/dev/null 2>&1; then
        fail "stable update eligibility must reject nightly versions"
    fi
    if "$eligibility" nightly 1.3.0 >/dev/null 2>&1; then
        fail "nightly update eligibility must reject stable versions"
    fi
fi

if [[ -x "$validate_credentials" ]]; then
    if "$validate_credentials" stable >/dev/null 2>&1; then
        fail "stable releases must reject missing signing and notarization credentials"
    fi
    DEVELOPER_ID_CERTIFICATE_BASE64=certificate \
        DEVELOPER_ID_CERTIFICATE_PASSWORD=password \
        DEVELOPER_IDENTITY=identity \
        APP_STORE_CONNECT_API_KEY_P8=notary-key \
        APP_STORE_CONNECT_API_KEY_ID=notary-key-id \
        APP_STORE_CONNECT_ISSUER_ID=notary-issuer-id \
        SPARKLE_EDDSA_PRIVATE_KEY=sparkle-key \
        SPARKLE_PUBLIC_ED_KEY='CtM67t8i60pFgyqC08m0za5aNl8anza7JZv6A93SILA=' \
        "$validate_credentials" stable >/dev/null \
        || fail "stable releases must accept a complete credential set"
    if "$validate_credentials" nightly >/dev/null 2>&1; then
        fail "nightly releases must reject missing signing credentials"
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
        "$appcast" stable 1.2.0 "$fixture/Debut.dmg" "$fixture/private-key" "$fixture/appcast.xml" "$plist" \
        >/dev/null
    expect_contains "$fixture/appcast.xml" 'releases/download/v1\.2\.0/Debut\.dmg' \
        "the appcast must point at the immutable versioned release asset"
    expect_contains "$fixture/appcast.xml" 'sparkle:edSignature="fixture-signature" length="1234"' \
        "the appcast must carry Sparkle's signature and exact archive length"
    SPARKLE_SIGN_UPDATE="$fake_signer" GITHUB_REPOSITORY=thomplth/debut \
        "$appcast" nightly 1.3.0-nightly.20260908 "$fixture/Debut.dmg" \
        "$fixture/private-key" "$fixture/nightly-appcast.xml" "$plist" >/dev/null
    expect_contains "$fixture/nightly-appcast.xml" '<title>Debut Nightly Updates</title>' \
        "nightly appcasts must identify their own channel"
    if SPARKLE_SIGN_UPDATE="$fake_signer" "$appcast" stable 1.2.1-nightly.20260908 \
        "$fixture/Debut.dmg" "$fixture/private-key" "$fixture/patch.xml" "$plist" >/dev/null 2>&1; then
        fail "stable appcast generation must refuse nightly versions"
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

expect_contains "$nightly" 'channel: nightly' "nightly releases must identify the nightly channel"
expect_contains "$nightly" 'SPARKLE_EDDSA_PRIVATE_KEY:.*secrets\.SPARKLE_EDDSA_PRIVATE_KEY' \
    "nightly appcasts must use the protected nightly Sparkle key"
expect_contains "$nightly" 'SPARKLE_PUBLIC_ED_KEY:.*vars\.SPARKLE_PUBLIC_ED_KEY' \
    "nightly builds must embed the nightly public key"
expect_contains "$manual" 'channel: stable' "manual releases must identify the stable channel"
manual_publish_job="$(sed -n '/^  publish:/,$p' "$manual")"
if ! grep -Eq '^    secrets: inherit$' <<< "$manual_publish_job"; then
    fail "the stable caller must enable protected environment secrets in the reusable workflow"
fi
nightly_publish_job="$(sed -n '/^  publish:/,$p' "$nightly")"
if grep -Eq '^    secrets: inherit$' <<< "$nightly_publish_job"; then
    fail "the nightly caller must not inherit stable release secrets"
fi
expect_contains "$publish_contract" "environment: stable$" \
    "release secrets must be isolated by channel environment"
expect_contains "$publish_contract" 'validate-release-credentials\.sh' \
    "publishing must fail before stamping or tagging when protected credentials are unavailable"
expect_contains "$publish_contract" 'update-eligibility\.sh' \
    "publishing must enforce channel-specific update eligibility"
expect_contains "$publish_contract" -- '--prerelease' "nightly GitHub releases must be prereleases"
expect_contains "$publish_contract" 'notarytool submit' "stable releases must be notarized"
expect_contains "$publish_contract" 'stapler staple' "stable releases must staple the notarization ticket"
expect_contains "$publish_contract" 'generate-appcast\.sh' "both release channels must generate an appcast"
expect_contains "$publish_contract" 'SPARKLE_EDDSA_PRIVATE_KEY' \
    "appcasts must be signed with each channel's protected Sparkle key"
expect_contains "$apply_version" 'releases/download/nightly-feed/appcast\.xml' \
    "nightly builds must use the isolated nightly feed"
expect_contains "$publish_contract" 'gh release (create|upload) nightly-feed' \
    "nightly publication must maintain the dedicated feed release"
expect_contains "$publish_contract" 'previous_update_tag' \
    "update verification must use a previous release from the same compatible channel"
expect_contains "$publish_contract" 'ci-update-e2e\.sh.*CHANNEL' \
    "both channels must exercise their own Sparkle update path"

if (( failures > 0 )); then
    exit 1
fi

echo "PASS: automatic update contract"
