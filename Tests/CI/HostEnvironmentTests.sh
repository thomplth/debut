#!/bin/bash
set -euo pipefail

# Hosted runners, the Tart guest and a developer's Mac disagree by default. Runners boot with
# Reduce Motion on, which turned a 0.36s spring into a 0.12s fade under an E2E check in August and
# a unit test in KHA-815; both passed locally and failed on CI. The contract is three rules:
# DebutCore reads host settings in one place, every disposable host applies one profile, and every
# run records what its host actually had.

cd "$(dirname "$0")/../.."

failures=0

fail() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

expect_contains() {
    grep -Eq -- "$2" "$1" || fail "$3"
}

expect_not_contains() {
    if grep -Eq -- "$2" "$1"; then
        fail "$3"
    fi
}

seam="Sources/DebutCore/HostEnvironment.swift"
profile="scripts/host-profile.sh"

# 1. One seam. A direct read anywhere else inherits whatever the host happens to say, in tests too.
[[ -f "$seam" ]] || fail "DebutCore must read host settings through $seam"
host_read_offenders="$(grep -rnE 'accessibilityDisplayShould|\\\.accessibility(Reduce|Differentiate|Invert|ShowButtonShapes)' \
    Sources/DebutCore | grep -v "^$seam:" || true)"
if [[ -n "$host_read_offenders" ]]; then
    fail "these read a host accessibility setting directly instead of through HostEnvironment:
$host_read_offenders"
fi
expect_contains "$seam" 'isDebutApp \? \.live : \.fixed' \
    "only the shipped app may follow the host; every other process gets the fixed profile"

# 2. One profile, applied by every disposable host.
[[ -x "$profile" ]] || fail "$profile must exist and be executable"
expect_contains "$profile" 'com\.apple\.universalaccess reduceMotion -bool false' \
    "the profile must pin Reduce Motion off, the spring every motion check samples"
expect_contains ".github/workflows/ci.yml" 'scripts/host-profile\.sh apply' \
    "the unit-test job must apply the host profile before swift test"
expect_contains "scripts/ci-e2e.sh" 'scripts/host-profile\.sh apply' \
    "hosted E2E must apply the host profile"
expect_contains "scripts/tart-e2e-guest.sh" '"\$HOST_PROFILE" apply' \
    "the Tart guest must apply the host profile"
expect_contains "scripts/tart-e2e.sh" 'scripts/host-profile\.sh' \
    "the Tart host must stage the profile beside the guest script"
for script in scripts/ci-e2e.sh scripts/tart-e2e-guest.sh; do
    expect_not_contains "$script" 'universalaccess' \
        "$script must leave accessibility pins to the host profile rather than keep its own copy"
done

# 3. Every run records the fingerprint where its evidence goes.
expect_contains ".github/workflows/e2e.yml" 'debut-e2e-host-profile\.json' \
    "hosted E2E evidence must include the host fingerprint"
expect_contains "scripts/tart-e2e-guest.sh" 'host-profile\.json' \
    "the Tart guest must return the host fingerprint with its results"
expect_contains "scripts/tart-run-report.sh" '"hostProfile"' \
    "report.json must carry the guest's host fingerprint"

# The profile itself: fingerprinting is read-only, applying refuses a developer's session.
if [[ -x "$profile" ]]; then
    scratch="$(mktemp -d)"
    trap 'rm -rf "$scratch"' EXIT
    if ! output="$(env -u GITHUB_ACTIONS -u DEBUT_HOST_PROFILE_DISPOSABLE \
        "$profile" fingerprint --out "$scratch/fingerprint.json" 2>&1)"; then
        fail "fingerprint must succeed on any host: $output"
    fi
    for key in reduceMotion reduceTransparency increaseContrast appearance windowAnimations \
        locale macOS xcode hardware virtualized displays; do
        [[ "$output" == *"host-profile: $key="* ]] || fail "fingerprint must print $key"
        grep -q "\"$key\":" "$scratch/fingerprint.json" 2>/dev/null \
            || fail "fingerprint JSON must record $key"
    done
    if command -v python3 >/dev/null 2>&1; then
        python3 -m json.tool "$scratch/fingerprint.json" >/dev/null 2>&1 \
            || fail "fingerprint JSON must parse"
    fi

    set +e
    refused="$(env -u GITHUB_ACTIONS -u DEBUT_HOST_PROFILE_DISPOSABLE "$profile" apply 2>&1)"
    refused_status=$?
    set -e
    (( refused_status != 0 )) || fail "apply must refuse to rewrite a non-disposable host's defaults"
    [[ "$refused" == *disposable* ]] || fail "apply's refusal must say why: $refused"
fi

if (( failures > 0 )); then
    echo "$failures host environment contract failure(s)" >&2
    exit 1
fi
echo "Host environment contract tests passed"
