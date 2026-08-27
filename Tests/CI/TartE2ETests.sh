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
    expect_contains "$host_runner" 'run-all' \
        "Tart E2E must expose an all-gesture diagnostic mode"
    expect_contains "$host_runner" 'run\) run_e2e virtualized' \
        "the default Tart loop must select virtualized skips"
    expect_contains "$host_runner" 'run-all\) run_e2e all' \
        "run-all must attempt every synthetic drag"
fi

if [[ -f "$guest_runner" ]]; then
    expect_contains "$guest_runner" 'kTCCServiceAccessibility' \
        "the disposable guest must provision Accessibility"
    expect_contains "$guest_runner" 'kTCCServicePostEvent' \
        "the guest E2E driver must be authorized to inject HID events"
    expect_contains "$guest_runner" 'unset GITHUB_ACTIONS' \
        "the isolated local guest must run hosted-skipped gesture checks"
    expect_contains "$guest_runner" 'DEBUT_SKIP_VIRTUALIZED_DRAGS' \
        "the default guest mode must identify unsupported virtualized drags"
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
    expect_contains "$guest_runner" 'DEBUT_SKIP_VIRTUALIZED_DRAGS="\$' \
        "the drag flag must be a scalar; bash 3.2 rejects empty array expansion under set -u"

    expect_mode_dispatch() {
        local mode="$1"
        local expected_status="$2"
        local expected_pattern="$3"
        local output status

        set +e
        output="$("$guest_runner" missing-app.zip missing-e2e "$mode" 2>&1)"
        status=$?
        set -e

        if (( status != expected_status )); then
            fail "guest mode '$mode' exited $status, expected $expected_status: $output"
        fi
        grep -Eq -- "$expected_pattern" <<< "$output" \
            || fail "guest mode '$mode' did not report '$expected_pattern': $output"
    }

    # Every mode must resolve before the guest is mutated, so an unusable mode
    # cannot leave a half-provisioned guest behind.
    expect_mode_dispatch bogus 2 'Unknown E2E mode'
    expect_mode_dispatch virtualized 1 'staged E2E artifacts are missing'
    expect_mode_dispatch all 1 'staged E2E artifacts are missing'
fi

if [[ -f "$e2e_source" ]]; then
    expect_contains "$e2e_source" 'DEBUT_SKIP_VIRTUALIZED_DRAGS' \
        "DebutE2E must recognize the virtualized drag skip flag"
    expect_contains "$e2e_source" 'Virtualized macOS does not deliver synthetic drag gestures' \
        "virtualized skips must explain why the check did not run"
fi

if (( failures > 0 )); then
    exit 1
fi

echo "PASS: Tart E2E contract"
