#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."
repo="$PWD"

failures=0
fail() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

planner="scripts/verify.sh"
[[ -x "$planner" ]] || { echo "FAIL: missing executable $planner" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# plan_paths <name-status lines...>: plans a synthetic change set, prints the JSON plan.
plan_paths() {
    printf '%s\n' "$@" > "$work/changes"
    "$planner" plan --changes "$work/changes" --json
}

field() {
    python3 -c 'import json,sys
d=json.loads(sys.stdin.read())
v=d
for k in sys.argv[1].split("."): v=v[k]
print(json.dumps(v) if isinstance(v,(list,dict,bool)) or v is None else v)' "$1"
}

expect_plan() {
    local description="$1" expected_e2e="$2" expected_swift="$3"
    shift 3
    local plan e2e swift
    plan="$(plan_paths "$@")" || { fail "$description: planner failed: $plan"; return; }
    e2e="$(field e2e <<< "$plan")"
    swift="$(field swiftTests <<< "$plan")"
    [[ "$e2e" == "$expected_e2e" ]] || fail "$description: e2e=$e2e, expected $expected_e2e"
    [[ "$swift" == "$expected_swift" ]] || fail "$description: swiftTests=$swift, expected $expected_swift"
}

# Prose needs no VM and no Swift build.
expect_plan "documentation only" '[]' false $'M\tdocs/privacy.md'
# A confined settings presentation change runs its consumers, not the whole suite.
expect_plan "settings window" '["rendering", "smoke"]' true $'M\tSources/DebutCore/Views/SettingsWindow.swift'
expect_plan "onboarding view" '["onboarding", "permissions", "smoke"]' true $'M\tSources/DebutCore/Views/OnboardingView.swift'
# Shared input, topology and movement have too many dependents to narrow.
expect_plan "space service" 'full' true $'M\tSources/DebutCore/Services/SpaceService.swift'
expect_plan "event tap" 'full' true $'M\tSources/DebutCore/Services/EventTapKeyboardService.swift'
expect_plan "app delegate" 'full' true $'M\tSources/DebutCore/AppDelegate.swift'
# Harness, build and permission plumbing change what every group means.
expect_plan "harness" 'full' true $'M\tSources/DebutE2E/main.swift'
expect_plan "tart runner" 'full' false $'M\tscripts/tart-e2e.sh'
expect_plan "package" 'full' true $'M\tPackage.swift'
# Unknown paths broaden rather than disappear.
expect_plan "unclassified path" 'full' true $'A\tsomewhere/new.bin'
# Unit-test-only changes need the Swift suite, not the VM.
expect_plan "unit tests" '[]' true $'M\tTests/DebutCoreTests/StageLayoutTests.swift'
# Mixed changes take the union; shared wins.
expect_plan "mixed docs and settings" '["rendering", "smoke"]' true \
    $'M\tdocs/privacy.md' $'M\tSources/DebutCore/Views/SettingsWindow.swift'
expect_plan "mixed settings and shared" 'full' true \
    $'M\tSources/DebutCore/Views/SettingsWindow.swift' $'M\tSources/DebutCore/Services/SpaceService.swift'
# Both sides of a rename count: moving a view into docs still changes the view.
expect_plan "rename out of a view" '["drag-drop", "fullscreen", "overlay-input", "rendering", "smoke"]' true \
    $'R100\tSources/DebutCore/Views/StageView.swift\tdocs/StageView.swift'
# A deletion counts as a change to what was deleted.
expect_plan "deleted service" 'full' true $'D\tSources/DebutCore/Services/StateStore.swift'

# Every group and reason is explained.
plan="$(plan_paths $'M\tSources/DebutCore/Views/SettingsWindow.swift')"
reasons="$(field reasons <<< "$plan")"
grep -q 'SettingsWindow.swift' <<< "$reasons" || fail "the plan must name the path behind each selection: $reasons"
[[ "$(field durationProfile <<< "$plan")" == null ]] \
    || fail "a plan without window moves has no duration sweep to profile"
not_selected="$(field notSelected <<< "$plan")"
grep -q 'window-moves' <<< "$not_selected" || fail "unselected groups must be listed explicitly: $not_selected"

# Window movement selects its sweep; shared routing selects the full sweep.
plan="$(plan_paths $'M\tSources/DebutCore/Services/SpaceService.swift')"
[[ "$(field durationProfile <<< "$plan")" == full ]] || fail "shared routing must sweep every duration"

# An empty change set selects nothing and says so.
plan="$(plan_paths "")"
[[ "$(field e2e <<< "$plan")" == '[]' && "$(field swiftTests <<< "$plan")" == false ]] \
    || fail "an empty change set must select nothing: $plan"

# A release always gets full coverage.
printf '%s\n' $'M\tdocs/privacy.md' > "$work/changes"
plan="$("$planner" plan --changes "$work/changes" --release --json)"
[[ "$(field e2e <<< "$plan")" == 'full' && "$(field durationProfile <<< "$plan")" == full ]] \
    || fail "a release must select full coverage: $plan"

# Every source rule selects at least one behavioral test.
"$planner" check-manifest >/dev/null 2>&1 || fail "the manifest has a source rule that selects no tests"

# --- Real git inputs: committed, staged, unstaged, untracked, renamed and deleted. ---
fixture="$work/repo"
mkdir -p "$fixture/docs" "$fixture/Sources/DebutCore/Views" "$fixture/Sources/DebutCore/Services" "$fixture/scripts/verify"
cp -R "$repo/scripts/verify.sh" "$fixture/scripts/"
cp -R "$repo/scripts/verify/." "$fixture/scripts/verify/"
echo a > "$fixture/docs/a.md"
echo v > "$fixture/Sources/DebutCore/Views/StageView.swift"
echo s > "$fixture/Sources/DebutCore/Services/StateStore.swift"
echo w > "$fixture/Sources/DebutCore/Views/SettingsWindow.swift"
git -C "$fixture" init -q -b main
git -C "$fixture" add -A
git -C "$fixture" -c user.email=t@t -c user.name=t commit -q -m base
base="$(git -C "$fixture" rev-parse HEAD)"

git -C "$fixture" switch -q -c topic
echo b >> "$fixture/docs/a.md"
git -C "$fixture" -c user.email=t@t -c user.name=t commit -qam committed
plan="$(cd "$fixture" && scripts/verify.sh plan --base "$base" --json)"
[[ "$(field e2e <<< "$plan")" == '[]' ]] || fail "a committed docs change must select no VM: $plan"

echo staged >> "$fixture/Sources/DebutCore/Views/SettingsWindow.swift"
git -C "$fixture" add Sources/DebutCore/Views/SettingsWindow.swift
plan="$(cd "$fixture" && scripts/verify.sh plan --base "$base" --json)"
grep -q 'rendering' <<< "$(field e2e <<< "$plan")" || fail "a staged change must be planned: $plan"
git -C "$fixture" -c user.email=t@t -c user.name=t commit -qm staged

echo unstaged >> "$fixture/Sources/DebutCore/Services/StateStore.swift"
plan="$(cd "$fixture" && scripts/verify.sh plan --base "$base" --json)"
[[ "$(field e2e <<< "$plan")" == 'full' ]] || fail "an unstaged change must be planned: $plan"
git -C "$fixture" checkout -q -- Sources/DebutCore/Services/StateStore.swift

echo untracked > "$fixture/Sources/DebutCore/Services/NewService.swift"
plan="$(cd "$fixture" && scripts/verify.sh plan --base "$base" --json)"
[[ "$(field e2e <<< "$plan")" == 'full' ]] || fail "an untracked source file must be planned: $plan"
rm "$fixture/Sources/DebutCore/Services/NewService.swift"

git -C "$fixture" mv Sources/DebutCore/Views/StageView.swift docs/StageView.md
plan="$(cd "$fixture" && scripts/verify.sh plan --base "$base" --json)"
grep -q 'overlay-input' <<< "$(field e2e <<< "$plan")" || fail "a staged rename must plan its old path: $plan"
git -C "$fixture" reset -q --hard

git -C "$fixture" rm -q Sources/DebutCore/Services/StateStore.swift
plan="$(cd "$fixture" && scripts/verify.sh plan --base "$base" --json)"
[[ "$(field e2e <<< "$plan")" == 'full' ]] || fail "a deletion must be planned: $plan"
git -C "$fixture" reset -q --hard

# An unavailable base cannot be narrowed from.
plan="$(cd "$fixture" && scripts/verify.sh plan --base no-such-ref --json)"
[[ "$(field e2e <<< "$plan")" == 'full' ]] || fail "an unavailable base must fall back to full: $plan"
grep -q 'base' <<< "$(field reasons <<< "$plan")" || fail "the fallback must say the base was unavailable"

# The plan names its inputs, so a stale plan can be detected.
plan="$(cd "$fixture" && scripts/verify.sh plan --base "$base" --json)"
[[ -n "$(field inputDigest <<< "$plan")" ]] || fail "the plan must carry an input digest"
echo more >> "$fixture/docs/a.md"
[[ "$(cd "$fixture" && scripts/verify.sh plan --base "$base" --json | field inputDigest)" != "$(field inputDigest <<< "$plan")" ]] \
    || fail "changing an input must change the plan's input digest"

if (( failures > 0 )); then
    exit 1
fi
echo "PASS: verification planner contract"
