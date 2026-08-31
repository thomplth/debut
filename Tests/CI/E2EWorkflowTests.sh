#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

workflow=".github/workflows/e2e.yml"
runner="scripts/ci-e2e.sh"
e2e_source="Sources/DebutE2E/main.swift"
tart_guest="scripts/tart-e2e-guest.sh"
signing_selector="scripts/select-signing-identity.sh"
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
expect_file "$tart_guest"
expect_file "$signing_selector"

if [[ -f "$workflow" ]]; then
    expect_contains "$workflow" '^  pull_request:' "E2E must run for pull requests"
    # A push run cannot fail a commit back out of main, so it buys nothing the release gates do
    # not already provide. E2E is a merge requirement for pull requests and a gate for releases.
    expect_not_contains "$workflow" '^  push:' "E2E must not run on pushes to main"
    expect_contains "$workflow" '^  workflow_dispatch:' "E2E must support manual runs"
    expect_contains "$workflow" 'runs-on: macos-26$' "E2E must use the free standard macOS 26 runner"
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
    expect_contains "$runner" 'launchctl setenv DEBUT_DISABLE_WINDOW_PREVIEWS 1' \
        "CI E2E must avoid live preview capture in the disposable app"
    # launchctl setenv only reaches launchd-spawned processes, so the shell-spawned suite would
    # otherwise assert against previews the app was told not to capture.
    expect_contains "$runner" 'export DEBUT_DISABLE_WINDOW_PREVIEWS=1' \
        "CI E2E must tell the suite process that previews are disabled"
    expect_contains "$runner" '/opt/hca/hosted-compute-agent' \
        "CI E2E must suppress capture reminders for the hosted runner process"
    expect_contains "$runner" 'killall replayd' \
        "CI E2E must reload replayd after changing its capture approval"
    expect_contains "$runner" 'com\.apple\.universalaccess reduceMotion -bool false' \
        "CI E2E must pin the host to the spring the motion check samples"
    expect_contains "$runner" './scripts/build-app.sh' "CI E2E entry point must build the app"
    expect_contains "$runner" 'sudo cp -R "\$app_bundle" "\$app_path"' \
        "CI E2E entry point must install the bundle build-app.sh reported"
    expect_contains "$runner" '\.build/release/DebutE2E' \
        "CI E2E entry point must reuse the release suite built with the app"
    expect_contains "$runner" "kTCCServiceScreenCapture','\\\$e2e_path'" \
        "the hosted suite must hold Screen Recording, since it samples frames in-process"
fi

if [[ -f "$e2e_source" ]]; then
    expect_contains "$e2e_source" 'Mission Control\.app/Contents/MacOS/Mission Control' \
        "E2E must invoke system overviews without relying on user shortcut settings"
    expect_contains "$e2e_source" 'hostedDragTests' \
        "E2E must isolate unsupported hosted drag assertions"
    expect_contains "$e2e_source" 'GitHub-hosted macOS does not deliver synthetic drag gestures' \
        "E2E must explain hosted drag-only skips"
    expect_contains "$e2e_source" 'previewCaptureTests' \
        "E2E must isolate assertions that need live preview capture"
    expect_contains "$e2e_source" 'Live preview capture is disabled' \
        "E2E must explain skips caused by disabled preview capture"
    expect_not_contains "$e2e_source" 'space_reordered_by_drag' \
        "E2E must not assert against space reordering, which Debut no longer does"
fi

if [[ -f "$tart_guest" ]]; then
    expect_contains "$tart_guest" 'DEBUT_FORCE_DISPLAY_STACK_INDICATOR' \
        "Tart E2E must enable the display indicator preview in the single-display VM"
    expect_contains "$tart_guest" 'Contents/MacOS/Debut" --force-display-stack-indicator' \
        "Tart E2E must launch Debut directly with the display indicator preview argument"
    expect_contains "$tart_guest" 'unsetenv DEBUT_FORCE_DISPLAY_STACK_INDICATOR' \
        "Tart E2E must clear the display indicator preview flag during cleanup"
fi

expect_not_contains "scripts/rebuild.sh" 'e2e-test\.sh' \
    "local rebuilds must no longer launch the disruptive E2E suite"
expect_contains "scripts/build-app.sh" 'select-signing-identity\.sh' \
    "build-app.sh must use the tested signing identity selector"
expect_contains "$signing_selector" 'find-identity.*\|\| true' \
    "CI builds must tolerate the absence of signing identities"
expect_contains "$signing_selector" '\$\{identity:--\}' \
    "CI builds must fall back to ad-hoc signing when no identity is available"

if (( failures > 0 )); then
    exit 1
fi

echo "PASS: E2E workflow contract"
