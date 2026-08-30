#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

ci=".github/workflows/ci.yml"
daily=".github/workflows/release-daily.yml"
manual=".github/workflows/release-manual.yml"
publish=".github/workflows/release-publish.yml"
e2e=".github/workflows/e2e.yml"
agents="AGENTS.md"
readme="README.md"
release_guide="docs/html/10-build-release.html"
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

for workflow in "$ci" "$daily" "$manual" "$publish" "$e2e"; do
    [[ -f "$workflow" ]] || fail "missing $workflow"
done

if [[ -f "$ci" ]]; then
    expect_contains "$ci" '^  pull_request:' "CI must run for pull requests"
    # A push run cannot fail a commit back out of main, so it buys nothing the release gates do
    # not already provide. CI is a merge requirement for pull requests and a gate for releases.
    expect_not_contains "$ci" '^  push:' "CI must not run on pushes to main"
    expect_contains "$ci" '^  workflow_call:' "CI must be callable as a release gate"
    expect_contains "$ci" 'runs-on: macos-26$' "CI must use the free standard macOS 26 runner"
    expect_not_contains "$ci" 'runs-on: .*-(large|xlarge)|runs-on: self-hosted' \
        "CI must not use a paid or developer-hosted runner"
    expect_contains "$ci" 'timeout-minutes:' "CI must have a runaway cost guard"
    # Several suites block the main thread, which starves main-queue work in suites running
    # alongside them. Parallel runs therefore fail on timing, not on behaviour.
    expect_contains "$ci" 'swift test --no-parallel' \
        "CI must run the test suite serially so main-thread blocking cannot starve other suites"
    expect_contains "$ci" 'Tests/CI/' "CI must run the shell contract tests"
    expect_contains "$ci" './scripts/build-app.sh' "CI must prove the release bundle still builds"
fi

if [[ -f "$e2e" ]]; then
    expect_contains "$e2e" '^  workflow_call:' "E2E must be callable as a release gate"
fi

# Both release paths must be gated by the same full CI and E2E suites.
for workflow in "$daily" "$manual"; do
    [[ -f "$workflow" ]] || continue
    name="$(basename "$workflow")"
    expect_contains "$workflow" 'uses: \./\.github/workflows/ci\.yml' \
        "$name must gate the release on CI"
    expect_contains "$workflow" 'uses: \./\.github/workflows/e2e\.yml' \
        "$name must gate the release on the E2E suite"
    expect_contains "$workflow" 'uses: \./\.github/workflows/release-publish\.yml' \
        "$name must publish through the shared release workflow"
    expect_contains "$workflow" 'needs: \[[^]]*ci[^]]*\]' \
        "$name must not publish before CI has passed"
    expect_contains "$workflow" 'needs: \[[^]]*e2e[^]]*\]' \
        "$name must not publish before E2E has passed"
    expect_contains "$workflow" 'scripts/release-plan\.sh' \
        "$name must derive the next version from the shared plan script"
    expect_contains "$workflow" 'concurrency:' \
        "$name must not race a second release"
    # Without this, anything landing on main during the gate window ships untested.
    expect_contains "$workflow" 'sha: \$\{\{ needs\.plan\.outputs\.sha \}\}' \
        "$name must publish the exact commit its gates tested"
done

if [[ -f "$daily" ]]; then
    expect_contains "$daily" '^  schedule:' "the daily release must run on a schedule"
    expect_contains "$daily" 'cron:' "the daily release must declare a cron expression"
    expect_contains "$daily" '^  workflow_dispatch:' "the daily release must be runnable on demand"
    expect_contains "$daily" 'release-plan\.sh patch --require-changes' \
        "the daily release must bump the patch number and skip when main has not moved"
    expect_contains "$daily" "should_release == 'true'" \
        "the daily release must skip its jobs when there is nothing to release"
fi

if [[ -f "$manual" ]]; then
    expect_not_contains "$manual" '^  schedule:' "the manual release must never run on a schedule"
    expect_contains "$manual" '^  workflow_dispatch:' "the manual release must be human triggered"
    expect_contains "$manual" 'type: choice' "the manual release must offer a bump choice"
    expect_contains "$manual" '^          - minor$' "the manual release must offer a minor bump"
    expect_contains "$manual" '^          - major$' "the manual release must offer a major bump"
    expect_contains "$manual" 'default: minor' "the manual release must default to the minor bump"
    expect_not_contains "$manual" '\-\-require-changes' \
        "a human-triggered release must not be skipped for want of new commits"
fi

expect_contains "$agents" 'single explicit user request' \
    "the agent release policy must treat one explicit user request as authorization"
expect_not_contains "$agents" 'approved through the protected' \
    "the agent release policy must not require a second stable-release approval"
expect_contains "$readme" 'single explicit release request' \
    "the public release documentation must describe one-request releases"
expect_not_contains "$readme" 'after approval' \
    "the public release documentation must not promise a separate approval gate"
expect_contains "$release_guide" 'single explicit release request' \
    "the build guide must describe one-request stable promotion"

if [[ -f "$publish" ]]; then
    expect_contains "$publish" '^  workflow_call:' "the publish workflow must only run as a called gate"
    expect_not_contains "$publish" '^  (schedule|pull_request|push):' \
        "the publish workflow must not be reachable without its gates"
    expect_contains "$publish" 'contents: write' "publishing must be able to push the tag and release"
    expect_contains "$publish" 'scripts/apply-version\.sh' \
        "the published build must report the version being released"
    expect_contains "$publish" 'scripts/release-notes\.sh' \
        "release notes must come from the commits being released"
    expect_contains "$publish" 'scripts/package-dmg\.sh' "the release must ship a disk image"
    expect_contains "$publish" '^      sha:' "the publish workflow must take the commit its gates tested"
    expect_contains "$publish" 'scripts/verify-release-commit\.sh' \
        "the publish workflow must refuse to release a commit its gates never saw"
    expect_contains "$publish" 'ref: \$\{\{ inputs\.sha \}\}' \
        "the publish workflow must check out the tested commit rather than whatever main is now"
    expect_contains "$publish" 'gh release create' "the workflow must create the GitHub release"
    expect_contains "$publish" 'Debut\.dmg' "the release must attach the disk image"
    expect_contains "$publish" 'git tag' "the release must be tagged"
    # main is protected by a ruleset that lets no bot update it, so a release that tries to push a
    # version-bump commit dies after building, having already pushed its tag. Tag the tested commit
    # in place and push nothing but the tag.
    expect_not_contains "$publish" 'git commit' \
        "the publish workflow must not commit, because it cannot push to protected main"
    expect_not_contains "$publish" 'git push .*HEAD:main|git push .*origin main' \
        "the publish workflow must never push a branch"
    expect_contains "$publish" 'git push origin "?\$\{?TAG' \
        "the publish workflow must push only the tag"
fi

# The badge is the only place a reader sees whether main is currently releasable. The gates run on
# pull requests alone, and a release calls them as reusable workflows, whose runs are attributed to
# the caller. Neither feeds a ci.yml or e2e.yml badge on main, so both would read "no status".
if [[ -f "README.md" ]]; then
    expect_contains "README.md" 'workflows/release-daily\.yml/badge\.svg' \
        "the README must show whether main is releasable"
    expect_not_contains "README.md" 'workflows/(ci|e2e)\.yml/badge\.svg' \
        "the README must not show a gate badge that no run on main can ever fill"
fi

if (( failures > 0 )); then
    exit 1
fi

echo "PASS: release workflow contract"
