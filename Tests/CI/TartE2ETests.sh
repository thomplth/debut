#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

host_runner="scripts/tart-e2e.sh"
guest_runner="scripts/tart-e2e-guest.sh"
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
        "Tart E2E must stage the release E2E executable"
    expect_contains "$host_runner" 'ARTIFACT_ID' \
        "warm-guest artifacts must use cache-busting names"
    expect_contains "$host_runner" 'app\.zip' \
        "the app must cross VirtioFS as one cache-safe archive"
    expect_contains "$host_runner" 'e2e-latest\.log' \
        "the host must retain guest output when E2E fails"
fi

if [[ -f "$guest_runner" ]]; then
    expect_contains "$guest_runner" 'kTCCServiceAccessibility' \
        "the disposable guest must provision Accessibility"
    expect_contains "$guest_runner" 'kTCCServicePostEvent' \
        "the guest E2E driver must be authorized to inject HID events"
    expect_contains "$guest_runner" 'unset GITHUB_ACTIONS' \
        "the isolated local guest must run hosted-skipped gesture checks"
    expect_contains "$guest_runner" 'TextEdit' \
        "the guest must create deterministic E2E fixture windows"
    expect_contains "$guest_runner" 'E2E_SOURCE' \
        "the guest must run the genuine E2E executable"
fi

if (( failures > 0 )); then
    exit 1
fi

echo "PASS: Tart E2E contract"
