#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."
repo="$PWD"

failures=0
fail() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A throwaway checkout with the verification scripts, so runs can change files freely.
fixture="$work/repo"
mkdir -p "$fixture/scripts/verify" "$fixture/docs" "$fixture/Sources/DebutCore/Views" \
    "$fixture/Sources/DebutCore/Services" "$fixture/Tests/CI"
cp "$repo/scripts/verify.sh" "$fixture/scripts/"
cp "$repo/scripts/verify/"* "$fixture/scripts/verify/"
echo a > "$fixture/docs/a.md"
echo v > "$fixture/Sources/DebutCore/Views/SettingsWindow.swift"
echo s > "$fixture/Sources/DebutCore/Services/SpaceService.swift"
git -C "$fixture" init -q -b main
git -C "$fixture" add -A
git -C "$fixture" -c user.email=t@t -c user.name=t commit -q -m base
base="$(git -C "$fixture" rev-parse HEAD)"

# Stub runners record their invocations. The Tart stub writes a report like tart-e2e.sh does,
# with the result taken from $STUB_TART_RESULT.
stubs="$work/stubs"
mkdir -p "$stubs"
cat > "$stubs/tart" <<'EOF'
#!/bin/bash
echo "tart $*" >> "$STUB_LOG"
run="$STUB_RUNS/run-$(date +%s)-$$-$RANDOM"
mkdir -p "$run"
printf '{"result": "%s"}\n' "${STUB_TART_RESULT:-passed}" > "$run/report.json"
echo "Tart E2E run x: ${STUB_TART_RESULT:-passed}"
echo "  evidence: $run"
[[ "${STUB_TART_RESULT:-passed}" == passed ]]
EOF
cat > "$stubs/swift" <<'EOF'
#!/bin/bash
echo "swift $*" >> "$STUB_LOG"
if [[ -n "${STUB_SWIFT_TOUCH:-}" ]]; then echo changed >> "$STUB_SWIFT_TOUCH"; fi
EOF
cat > "$stubs/contracts" <<'EOF'
#!/bin/bash
echo "contracts" >> "$STUB_LOG"
EOF
chmod +x "$stubs"/*

export STUB_LOG="$work/log" STUB_RUNS="$work/runs"
export DEBUT_VERIFY_TART="$stubs/tart" DEBUT_VERIFY_SWIFT_TEST="$stubs/swift" \
    DEBUT_VERIFY_CONTRACTS="$stubs/contracts" DEBUT_VERIFY_STATE="$work/state"

verify() {
    (cd "$fixture" && scripts/verify.sh "$@")
}

# --- Affected runs execute exactly what the plan selects. ---
: > "$STUB_LOG"
echo b >> "$fixture/docs/a.md"
verify affected --base "$base" > "$work/out" 2>&1 || fail "a docs change must verify: $(cat "$work/out")"
[[ "$(cat "$STUB_LOG")" == contracts ]] || fail "a docs change must run contracts only: $(tr '\n' ';' < "$STUB_LOG")"
git -C "$fixture" checkout -q -- docs/a.md

: > "$STUB_LOG"
echo w >> "$fixture/Sources/DebutCore/Views/SettingsWindow.swift"
verify affected --base "$base" > "$work/out" 2>&1 || fail "a settings change must verify: $(cat "$work/out")"
grep -q '^swift test --no-parallel$' "$STUB_LOG" || fail "a source change must run the serial Swift suite"
grep -q '^tart run --groups rendering,smoke --duration-profile ordinary$' "$STUB_LOG" \
    || fail "a settings change must run its groups, with the gallery for rendering: $(tr '\n' ';' < "$STUB_LOG")"
git -C "$fixture" checkout -q -- Sources/DebutCore/Views/SettingsWindow.swift

: > "$STUB_LOG"
echo t >> "$fixture/Sources/DebutCore/Services/SpaceService.swift"
verify affected --base "$base" > "$work/out" 2>&1 || fail "a shared change must verify"
grep -q '^tart run --duration-profile full$' "$STUB_LOG" \
    || fail "a shared change must run the full suite and sweep: $(tr '\n' ';' < "$STUB_LOG")"

: > "$STUB_LOG"
verify full > "$work/out" 2>&1 || fail "full must verify"
grep -q '^tart run --duration-profile full$' "$STUB_LOG" || fail "full must run every group"
grep -q '^swift test --no-parallel$' "$STUB_LOG" || fail "full must run the Swift suite"

# --- A plan whose inputs change before the VM run is refused, not run stale. ---
: > "$STUB_LOG"
set +e
STUB_SWIFT_TOUCH="$fixture/Sources/DebutCore/Services/SpaceService.swift" \
    verify affected --base "$base" > "$work/out" 2>&1
stale_status=$?
set -e
(( stale_status != 0 )) || fail "a plan whose inputs changed mid-run must fail"
grep -q '^tart' "$STUB_LOG" && fail "a stale plan must not reach the VM"
grep -qi 'changed' "$work/out" || fail "the refusal must say the inputs changed: $(cat "$work/out")"

# --- Unchanged infrastructure failures get one recovery retry, then stop. ---
rm -rf "$DEBUT_VERIFY_STATE"
export STUB_TART_RESULT=setup_failure
verify affected --base "$base" > /dev/null 2>&1 && fail "a setup failure must fail the run"
verify affected --base "$base" > "$work/out" 2>&1 && fail "the recovery retry still fails here"
grep -qi 'recovery retry' "$work/out" || fail "the retry must be named as the one recovery retry: $(cat "$work/out")"
: > "$STUB_LOG"
set +e
verify affected --base "$base" > "$work/out" 2>&1
third_status=$?
set -e
(( third_status != 0 )) || fail "a third attempt on unchanged inputs must be refused"
grep -q '^tart' "$STUB_LOG" && fail "a refused retry must not reach the VM"
grep -q 'evidence' "$work/out" || fail "the refusal must point at the retained evidence: $(cat "$work/out")"

# A stated reason unlocks another attempt and is recorded.
: > "$STUB_LOG"
verify affected --base "$base" --retry-reason "repaired the VM keychain" > /dev/null 2>&1 || true
grep -q '^tart' "$STUB_LOG" || fail "--retry-reason must allow another attempt"
grep -rq 'repaired the VM keychain' "$DEBUT_VERIFY_STATE" || fail "the retry reason must be recorded"

# --- A failed assertion on unchanged inputs is not retried for a green aggregate. ---
rm -rf "$DEBUT_VERIFY_STATE"
export STUB_TART_RESULT=failed
verify affected --base "$base" > /dev/null 2>&1 && fail "a failed suite must fail the run"
: > "$STUB_LOG"
verify affected --base "$base" > "$work/out" 2>&1 && fail "an unchanged rerun of a failure must be refused"
grep -q '^tart' "$STUB_LOG" && fail "an unchanged rerun of a failure must not reach the VM"

# Changing an input resets the count.
echo u >> "$fixture/Sources/DebutCore/Services/SpaceService.swift"
: > "$STUB_LOG"
verify affected --base "$base" > /dev/null 2>&1 || true
grep -q '^tart' "$STUB_LOG" || fail "a changed input must be allowed to run again"
unset STUB_TART_RESULT

if (( failures > 0 )); then
    exit 1
fi
echo "PASS: verification runner contract"
