#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."
repo="$PWD"

failures=0
fail() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

report_lib="scripts/tart-run-report.sh"
[[ -f "$report_lib" ]] || { echo "FAIL: missing $report_lib" >&2; exit 1; }
# shellcheck source=/dev/null
source "$report_lib"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

json_field() {
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): d=d[k] if not isinstance(d,list) else d[int(k)]
print(d)' "$1" "$2"
}

# --- Source identity covers staged, unstaged and untracked inputs, not only HEAD. ---
fixture="$work/repo"
mkdir -p "$fixture"
git -C "$fixture" init -q
git -C "$fixture" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
echo one > "$fixture/tracked.txt"
git -C "$fixture" add tracked.txt
git -C "$fixture" -c user.email=t@t -c user.name=t commit -q -m tracked

clean="$(run_report_source_identity "$fixture")"
grep -q '"dirty": false' <<< "$clean" || fail "a clean tree must report dirty=false: $clean"
echo two > "$fixture/tracked.txt"
modified="$(run_report_source_identity "$fixture")"
grep -q '"dirty": true' <<< "$modified" || fail "an unstaged edit must report dirty=true"
[[ "$modified" != "$clean" ]] || fail "an unstaged edit must change the source identity"
echo new > "$fixture/untracked.txt"
untracked="$(run_report_source_identity "$fixture")"
[[ "$untracked" != "$modified" ]] || fail "an untracked file must change the source identity"
echo newer > "$fixture/untracked.txt"
[[ "$(run_report_source_identity "$fixture")" != "$untracked" ]] \
    || fail "an untracked file's content must change the source identity"
git -C "$fixture" add untracked.txt
[[ "$(run_report_source_identity "$fixture")" == "$(run_report_source_identity "$fixture")" ]] \
    || fail "the source identity must be deterministic"

# --- Phases are timed with a monotonic clock and never overlap. ---
fake_clock="$work/clock"
echo 1000 > "$fake_clock"
run_report_now_ms() { cat "$fake_clock"; }
advance() { echo $(( $(<"$fake_clock") + $1 )) > "$fake_clock"; }

RUN_DIR="$work/run-a"
mkdir -p "$RUN_DIR"
run_report_phase build advance 400
run_report_phase queue advance 250
set +e
run_report_phase stage false
stage_status=$?
set -e
(( stage_status == 1 )) || fail "a failing phase must return its failure"
phases="$(cat "$RUN_DIR/phases.tsv")"
expected=$'build\t1000\t1400\t0\nqueue\t1400\t1650\t0\nstage\t1650\t1650\t1'
[[ "$phases" == "$expected" ]] || fail "phase records were wrong: $(tr '\t\n' ' |' <<< "$phases")"
[[ "$(run_report_reached)" == stage ]] || fail "the last phase entered must be reported as reached"

# Under errexit a failing phase exits the script; the exit handler closes the phase it was in.
# Run bare: an `|| true` here would switch errexit off inside the subshell too.
set +e
(
    set -e
    run_report_phase provision advance 100
    run_report_phase guest false
    echo unreachable
) > "$work/errexit.out" 2>&1
set -e
grep -q unreachable "$work/errexit.out" && fail "a failing phase must still stop the script under set -e"
[[ "$(run_report_reached)" == guest ]] || fail "an interrupted phase must be reported as reached"
run_report_close_phase 1
[[ "$(tail -1 "$RUN_DIR/phases.tsv" | cut -f1,4)" == $'guest\t1' ]] \
    || fail "closing an interrupted phase must record its failure"

# --- A run is classified by how far it got, not only by its exit status. ---
check_result() {
    local expected="$1" status="$2" reached="$3" suite_started="$4" canceled="$5" actual
    actual="$(run_report_classify "$status" "$reached" "$suite_started" "$canceled")"
    [[ "$actual" == "$expected" ]] \
        || fail "status=$status reached=$reached suite=$suite_started canceled=$canceled classified $actual, expected $expected"
}
check_result passed 0 collect true false
check_result failed 1 guest true false
check_result setup_failure 1 guest false false
check_result setup_failure 1 boot false false
check_result setup_failure 1 build false false
check_result canceled 130 queue false true
check_result canceled 130 guest true true

# --- The report is valid JSON carrying the identity, phases, result and check counts. ---
RUN_DIR="$work/runs/20260926T000000-1"
mkdir -p "$RUN_DIR/results/checks"
printf 'build\t0\t500\t0\nsuite\t500\t2500\t0\n' > "$RUN_DIR/phases.tsv"
printf 'install\t10\t20\nsuite\t20\t1800\n' > "$RUN_DIR/results/guest-phases.tsv"
cat > "$RUN_DIR/results/checks/suite.json" <<'EOF'
{"invocation": "suite", "checks": [
 {"section": "1. Baseline", "name": "a", "status": "passed"},
 {"section": "1. Baseline", "name": "b", "status": "failed"},
 {"section": "2. Other", "name": "c", "status": "skipped", "reason": "no fixture"}
]}
EOF
run_report_write "$RUN_DIR" failed '{"commit": "abc", "dirty": false}' \
    '{"durationProfile": "ordinary", "gallery": "off"}' '{"app": "sha"}' '{"buildCpuSeconds": 1.5}'
report="$RUN_DIR/report.json"
python3 -m json.tool "$report" >/dev/null 2>&1 || fail "report.json is not valid JSON"
[[ "$(json_field "$report" result)" == failed ]] || fail "report lost the result"
[[ "$(json_field "$report" source.commit)" == abc ]] || fail "report lost the source identity"
[[ "$(json_field "$report" selection.durationProfile)" == ordinary ]] || fail "report lost the selection"
[[ "$(json_field "$report" hostPhases.1.name)" == suite ]] || fail "report lost host phases"
[[ "$(json_field "$report" hostPhases.1.seconds)" == 2.0 ]] || fail "host phase seconds were wrong"
[[ "$(json_field "$report" guestPhases.1.seconds)" == 1.78 ]] || fail "guest phases must use the guest's own clock"
[[ "$(json_field "$report" checks.failed)" == 1 ]] || fail "report did not count failed checks"
[[ "$(json_field "$report" checks.skipped)" == 1 ]] || fail "report did not count skipped checks"
[[ "$(json_field "$report" checks.failures.0)" == "1. Baseline: b" ]] || fail "report did not name failed checks"
summary="$(run_report_summary "$RUN_DIR")"
grep -q 'failed' <<< "$summary" && grep -q 'suite 2.0s' <<< "$summary" \
    || fail "the summary must state the result and phase times: $summary"

# --- Retention keeps recent and failed runs and never deletes the active one. ---
runs="$work/prune"
make_run() {
    mkdir -p "$runs/$1"
    printf '{"result": "%s"}\n' "$2" > "$runs/$1/report.json"
}
make_run 20260101T000001-1 failed
make_run 20260101T000002-1 passed
make_run 20260101T000003-1 failed
make_run 20260101T000004-1 passed
make_run 20260101T000005-1 passed
make_run 20260101T000006-1 setup_failure
mkdir -p "$runs/20260101T000000-9"  # active: no report yet
run_report_prune "$runs" 2 "$runs/20260101T000000-9"
kept="$(ls "$runs" | tr '\n' ' ')"
for expected_kept in 20260101T000006-1 20260101T000005-1 20260101T000003-1 20260101T000000-9; do
    [[ -d "$runs/$expected_kept" ]] || fail "retention removed $expected_kept; kept: $kept"
done
for expected_gone in 20260101T000001-1 20260101T000002-1; do
    [[ ! -d "$runs/$expected_gone" ]] || fail "retention kept $expected_gone beyond its bound; kept: $kept"
done

# --- Child CPU is read in this shell; `times` in a subshell sees no children at all. ---
run_report_children_cpu_seconds
before_cpu="$RUN_REPORT_CPU"
/usr/bin/perl -MTime::HiRes=time -e 'my $end = time + 1; 1 while time < $end'
run_report_children_cpu_seconds
after_cpu="$RUN_REPORT_CPU"
awk -v a="$before_cpu" -v b="$after_cpu" 'BEGIN { exit !(b - a >= 0.5) }' \
    || fail "a CPU-bound child must be counted (before=$before_cpu after=$after_cpu)"

# --- Cancelling reaches a long-running phase at once, and takes its children with it. ---
cat > "$work/cancel.sh" <<EOF
#!/bin/bash
set -euo pipefail
source "$PWD/$report_lib"
trap 'run_report_kill_children; exit 130' INT TERM
long_phase() { /bin/sleep 30 | /bin/cat; }
run_report_interruptibly long_phase
echo finished
EOF
chmod +x "$work/cancel.sh"
"$work/cancel.sh" > "$work/cancel.out" 2>&1 &
cancel_pid=$!
sleep 1
started="$(date +%s)"
kill -TERM "$cancel_pid"
set +e
wait "$cancel_pid"
cancel_status=$?
set -e
(( $(date +%s) - started <= 3 )) || fail "cancellation waited for the running phase to finish"
(( cancel_status == 130 )) || fail "a cancelled run must exit 130, got $cancel_status"
grep -q finished "$work/cancel.out" && fail "a cancelled phase must not continue"
pgrep -f '/bin/sleep 30' >/dev/null && fail "cancellation left the phase's children running"

# A failing interruptible phase reports its status without switching errexit off inside it.
set +e
( set -e; failing() { false; echo "kept going"; }; run_report_interruptibly failing ) > "$work/errexit2.out" 2>&1
interrupt_status=$?
set -e
(( interrupt_status == 1 )) || fail "an interruptible phase must return its command's status, got $interrupt_status"
grep -q 'kept going' "$work/errexit2.out" && fail "errexit must still apply inside an interruptible phase"

# A run without a report is still running or waiting in the queue: its directory is created before
# it queues. Pruning must leave it alone, and must not fail the finishing run under errexit.
runs="$work/prune-live"
for n in 1 2 3 4 5 6 7 8; do
    mkdir -p "$runs/20260102T00000$n-1"
    printf '{\n  "schemaVersion": 1,\n  "result": "passed"\n}\n' > "$runs/20260102T00000$n-1/report.json"
done
mkdir -p "$runs/20260102T000009-2"   # another run, still going
set +e
( set -euo pipefail; run_report_prune "$runs" 2 "$runs/20260102T000008-1" )
prune_status=$?
set -e
(( prune_status == 0 )) || fail "pruning must not fail the run that finishes (exit $prune_status)"
[[ -d "$runs/20260102T000009-2" ]] || fail "pruning deleted another run's live directory"
[[ ! -d "$runs/20260102T000001-1" ]] || fail "pruning must still remove old finished runs read from pretty-printed reports"

# --- ps CPU times parse in every format ps prints. ---
[[ "$(run_report_ps_seconds '0:01.50')" == 1.5 ]] || fail "M:SS.ss CPU time parsed wrong"
[[ "$(run_report_ps_seconds '1:02:03')" == 3723.0 ]] || fail "H:MM:SS CPU time parsed wrong"
[[ "$(run_report_ps_seconds '2-01:00:00')" == 176400.0 ]] || fail "D-HH:MM:SS CPU time parsed wrong"

# --- The runner wires all of this into the real run. ---
host_runner="scripts/tart-e2e.sh"
guest_runner="scripts/tart-e2e-guest.sh"
grep -q 'source .*tart-run-report\.sh' "$host_runner" || fail "tart-e2e.sh must use the run report"
for phase in build queue stage boot provision guest collect; do
    grep -Eq "run_report_phase $phase " "$host_runner" || fail "tart-e2e.sh must time the $phase phase"
done
grep -q 'run_report_prune' "$host_runner" || fail "tart-e2e.sh must bound retained runs"
grep -q 'run_report_source_identity' "$host_runner" || fail "tart-e2e.sh must record the source identity"
grep -q 'rm -rf "\$SHARE_DIR/results"' "$host_runner" \
    && ! grep -q 'mv "\$SHARE_DIR/results"' "$host_runner" \
    && fail "tart-e2e.sh must move results into the run directory before the next run clears them"
grep -q 'guest-phases\.tsv' "$guest_runner" || fail "the guest must record its own phase timings"
grep -q 'debut-e2e-results' "$guest_runner" || fail "the guest must collect per-check results"
grep -q 'debut-e2e-results' Sources/DebutE2E/main.swift || fail "DebutE2E must write per-check results"

cd "$repo"
if (( failures > 0 )); then
    exit 1
fi
echo "PASS: Tart run report contract"
