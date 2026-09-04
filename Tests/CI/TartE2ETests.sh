#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

host_runner="scripts/tart-e2e.sh"
guest_runner="scripts/tart-e2e-guest.sh"
e2e_source="Sources/DebutE2E/main.swift"
failures=0

fail() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

expect_contains() {
    local path="$1"
    local pattern="$2"
    local message="$3"
    grep -Eq -- "$pattern" "$path" || fail "$message"
}

expect_not_contains() {
    local path="$1"
    local pattern="$2"
    local message="$3"
    if grep -Eq -- "$pattern" "$path"; then
        fail "$message"
    fi
}

[[ -x "$host_runner" ]] || fail "missing executable $host_runner"
[[ -x "$guest_runner" ]] || fail "missing executable $guest_runner"
[[ -f "$e2e_source" ]] || fail "missing $e2e_source"

if [[ -f "$host_runner" ]]; then
    expect_contains "$host_runner" 'ghcr\.io/cirruslabs/macos-tahoe-base:latest' \
        "Tart setup must use the official Tahoe base image"
    expect_contains "$host_runner" 'tart run.*--no-graphics' \
        "Tart E2E must not open a host-side VM window"
    expect_contains "$host_runner" 'tart run.*--no-pointer.*--no-keyboard' \
        "Tart E2E must not attach host input devices"
    expect_contains "$host_runner" 'tart exec' \
        "Tart E2E must use the guest agent to bootstrap SSH"
    expect_not_contains "$host_runner" 'tart exec -t' \
        "Tart E2E must not require an interactive host terminal"
    expect_contains "$host_runner" 'ssh-keygen' \
        "Tart E2E must create an isolated guest key without prompting"
    expect_contains "$host_runner" 'ssh .*admin@' \
        "the E2E input driver must be launched by the image-authorized SSH service"
    expect_contains "$host_runner" 'DebutE2E' \
        "Tart E2E must space the release E2E executable"
    expect_contains "$host_runner" 'ARTIFACT_ID' \
        "warm-guest artifacts must use cache-busting names"
    expect_contains "$host_runner" 'app\.zip' \
        "the app must cross VirtioFS as one cache-safe archive"
    expect_contains "$host_runner" 'e2e-latest\.log' \
        "the host must retain guest output when E2E fails"
    expect_contains "$host_runner" 'run\) run_e2e' \
        "the Tart loop must expose a run mode"
    expect_not_contains "$host_runner" 'run-all' \
        "a diagnostic mode that only re-enables virtualized drags has nothing left to enable"
fi

if [[ -f "$guest_runner" ]]; then
    expect_contains "$guest_runner" 'kTCCServiceAccessibility' \
        "the disposable guest must provision Accessibility"
    expect_contains "$guest_runner" 'kTCCServicePostEvent' \
        "the guest E2E driver must be authorized to inject HID events"
    expect_contains "$guest_runner" 'grant_screen_capture "\$E2E_SOURCE"' \
        "the guest suite must hold Screen Recording, since it samples frames in-process"
    expect_contains "$guest_runner" 'unset GITHUB_ACTIONS' \
        "the isolated local guest must run hosted-skipped gesture checks"
    expect_not_contains "$guest_runner" 'DEBUT_SKIP_VIRTUALIZED_DRAGS' \
        "the guest attempts synthetic drags; there is no virtualized skip to set"
    expect_contains "$guest_runner" 'com\.apple\.universalaccess reduceMotion -bool false' \
        "the guest must pin the host to the spring the motion check samples"
    expect_contains "$guest_runner" 'TextEdit' \
        "the guest must create deterministic E2E fixture windows"
    expect_contains "$guest_runner" 'wait_for_fixture_apps' \
        "the guest must wait for both fixture apps before launching Debut"
    expect_contains "$guest_runner" 'pgrep -x TextEdit' \
        "fixture readiness must observe the TextEdit processes"
    expect_contains "$guest_runner" 'E2E_SOURCE' \
        "the guest must run the genuine E2E executable"
    expect_contains "$guest_runner" 'wait_for_debut_ready' \
        "the guest must gate E2E on Debut readiness"
    expect_contains "$guest_runner" 'app_ready' \
        "guest readiness must require the app-ready diagnostic event"
    expect_contains "$guest_runner" 'state\.eventTapRunning' \
        "guest readiness must require the keyboard event tap"
    expect_contains "$guest_runner" 'state\.windowsInActiveSpace' \
        "guest readiness must require discovered fixture windows"
    expect_not_contains "$guest_runner" 'unzip -Z1.*awk.*exit' \
        "archive discovery must drain large framework bundles instead of SIGPIPE under pipefail"

    # Staged artifacts must be checked before the guest is mutated, so an unusable
    # invocation cannot leave a half-provisioned guest behind.
    set +e
    missing_output="$("$guest_runner" missing-app.zip missing-e2e 2>&1)"
    missing_status=$?
    set -e
    if (( missing_status != 1 )); then
        fail "guest exited $missing_status on missing artifacts, expected 1: $missing_output"
    fi
    grep -Eq -- 'staged E2E artifacts are missing' <<< "$missing_output" \
        || fail "guest did not report missing staged artifacts: $missing_output"
fi

if [[ -f "$e2e_source" ]]; then
    # Tart delivers synthetic drags: `run-all` passed 53/53 including a real cross-space
    # window move and its reverse. The skip predated the TCC-alert root cause (KHA-612)
    # that explained every other pointer failure in the VM.
    expect_not_contains "$e2e_source" 'DEBUT_SKIP_VIRTUALIZED_DRAGS' \
        "virtualized drags are attempted, so no flag may suppress them"
    expect_not_contains "$e2e_source" 'Virtualized macOS does not deliver synthetic drag gestures' \
        "the virtualized drag skip and its wording are retired"

    # LaunchServices answers a bundle-ID lookup with one bundle even when several claim the ID,
    # and its choice between them is not stable. A stale probe app declaring com.thomplth.Debut
    # took two consecutive runs before a single check ran: it launched, crashed, and the missing
    # app_ready read as Debut failing to start.
    expect_contains "$e2e_source" 'urlsForApplications\(withBundleIdentifier' \
        "DebutE2E must see every bundle claiming Debut's identifier"
    expect_not_contains "$e2e_source" 'urlForApplication\(withBundleIdentifier: (debutBundleID|"com\.thomplth\.Debut")' \
        "a single-answer lookup cannot tell a hijacked launch from a real one"
    expect_contains "$e2e_source" 'claim the bundle identifier' \
        "an ambiguous install must be named and refused, not silently resolved"
fi

if (( failures > 0 )); then
    exit 1
fi

echo "PASS: Tart E2E contract"
