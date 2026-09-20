#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

agent_guide="AGENTS.md"
local_guide="docs/local-e2e.md"
failures=0

fail() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

expect_contains() {
    local path="$1"
    local pattern="$2"
    local message="$3"
    grep -Eiq -- "$pattern" "$path" || fail "$message"
}

for path in "$agent_guide" "$local_guide"; do
    [[ -f "$path" ]] || fail "missing $path"
done

expect_contains "$agent_guide" 'only.*E2E.*high-risk|E2E.*only.*high-risk' \
    "agent guidance must reserve E2E for high-risk changes"
expect_contains "$agent_guide" 'prioriti[sz]e.*headless.*Tart|headless.*Tart.*first' \
    "agent guidance must prioritize the headless Tart VM"
expect_contains "$agent_guide" './scripts/tart-e2e\.sh run' \
    "agent guidance must provide the stable Tart command"
expect_contains "$agent_guide" 'foreground.*developer|developer.*foreground' \
    "agent guidance must warn against foreground E2E"

expect_contains "$local_guide" 'high-risk changes only' \
    "local E2E guide must state the high-risk-only policy"
expect_contains "$local_guide" 'preferred.*headless|headless.*preferred' \
    "local E2E guide must identify headless Tart as preferred"
expect_contains "$local_guide" 'GitHub-hosted.*fallback|fallback.*GitHub-hosted' \
    "local E2E guide must describe hosted CI as the fallback"

if (( failures > 0 )); then
    exit 1
fi

echo "PASS: E2E documentation policy"
