#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

workflow=".github/workflows/e2e.yml"
runner="scripts/ci-e2e.sh"
e2e_source="Sources/DebutE2E/main.swift"
failures=0

fail() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

expect_file() {
    local path="$1"
    [[ -f "$path" ]] || fail "missing $path"
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

expect_file "$workflow"
expect_file "$runner"
expect_file "$e2e_source"

if [[ -f "$workflow" ]]; then
    expect_contains "$workflow" '^  pull_request:' "E2E must run for pull requests"
    expect_contains "$workflow" '^  push:' "E2E must run for pushes to main"
    expect_contains "$workflow" '^  workflow_dispatch:' "E2E must support manual runs"
    expect_contains "$workflow" 'runs-on: macos-15$' "E2E must use the free standard macOS 15 runner"
    expect_not_contains "$workflow" 'runs-on: .*-(large|xlarge)|runs-on: self-hosted' \
        "E2E must not use a paid or developer-hosted runner"
    expect_contains "$workflow" 'timeout-minutes:' "E2E must have a runaway cost guard"
    expect_contains "$workflow" 'run: ./scripts/ci-e2e.sh' "workflow must use the CI E2E entry point"
    expect_contains "$workflow" 'if: always\(\)' "E2E artifacts must upload after failures"
    expect_contains "$workflow" '/tmp/debut-e2e-screenshots' "workflow must upload E2E screenshots"
fi

if [[ -f "$runner" ]]; then
    expect_contains "$runner" 'GITHUB_ACTIONS' "CI E2E entry point must reject accidental local runs"
    expect_contains "$runner" 'Xcode_26\.3\.app' "CI E2E must select an installed macOS 26 SDK"
    expect_contains "$runner" 'ScreenCaptureApprovals\.plist' \
        "CI E2E must suppress the hosted runner's screen capture reminder"
    expect_contains "$runner" 'kTCCServiceScreenCapture' \
        "CI E2E must grant Debut screen capture access in the disposable account"
    if (( $(grep -c 'kTCCServiceScreenCapture' "$runner") < 2 )); then
        fail "CI E2E must grant Debut screen capture access in both TCC databases"
    fi
    if grep 'kTCCServiceScreenCapture.*X'"'" "$runner" >/dev/null; then
        fail "CI screen capture grants must not pin the disposable ad-hoc signature"
    fi
    expect_contains "$runner" 'app_executable=.*Contents/MacOS/Debut' \
        "CI E2E must grant the ad-hoc executable path screen capture access"
    expect_contains "$runner" 'launchctl setenv DEBUT_DISABLE_WINDOW_PREVIEWS 1' \
        "CI E2E must avoid live preview capture in the disposable app"
    expect_not_contains "$runner" 'sudo sqlite3 "\$user_tcc_db"' \
        "CI E2E must update the user TCC database as the runner user"
    expect_contains "$runner" '/opt/hca/hosted-compute-agent' \
        "CI E2E must suppress capture reminders for the hosted runner process"
    expect_contains "$runner" 'killall replayd' \
        "CI E2E must reload replayd after changing its capture approval"
    expect_contains "$runner" './scripts/build-app.sh' "CI E2E entry point must build the app"
    expect_contains "$runner" '/Applications/Debut.app' "CI E2E entry point must install the app"
    expect_contains "$runner" '\.build/release/DebutE2E' \
        "CI E2E entry point must reuse the release suite built with the app"
fi

if [[ -f "$e2e_source" ]]; then
    expect_contains "$e2e_source" 'Mission Control\.app/Contents/MacOS/Mission Control' \
        "E2E must invoke system overviews without relying on user shortcut settings"
    expect_contains "$e2e_source" 'postMouseHover\(to: handleHotspot\)' \
        "E2E must generate continuous movement inside the stage handle hotspot"
    expect_contains "$e2e_source" 'postMouseHover\(to: reverseHotspot\)' \
        "E2E must generate continuous movement inside the reverse handle hotspot"
fi

expect_not_contains "scripts/rebuild.sh" 'e2e-test\.sh' \
    "local rebuilds must no longer launch the disruptive E2E suite"
expect_contains "scripts/build-app.sh" 'SIGN_IDENTITY=.*\|\| true' \
    "CI builds must fall back to ad-hoc signing when Debut Dev is absent"

if (( failures > 0 )); then
    exit 1
fi

echo "PASS: E2E workflow contract"
