#!/bin/bash
# What a local Tart run did, how long each part took, and exactly what it tested.
#
# Sourced by tart-e2e.sh. Each run gets its own directory under $SHARE_DIR/runs holding the
# host log, the guest's results and a report.json, so a failure survives the next run instead
# of being overwritten. Host phases use this machine's monotonic clock; the guest records its
# own phases with its own clock, and the two are never subtracted from each other.
#
# macOS ships bash 3.2: no EPOCHREALTIME, associative arrays or mapfile here.

RUN_DIR="${RUN_DIR:-}"

run_report_now_ms() {
    /usr/bin/perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC \
        -e 'printf "%.0f", clock_gettime(CLOCK_MONOTONIC) * 1000'
}

# run_report_phase <name> <command...>
# Runs the command, appends "name<TAB>start<TAB>end<TAB>status" and returns its status.
# The command runs bare, not in an `if` or `||`, which would switch off `set -e` for every
# command inside it; under errexit a failure exits here and run_report_close_phase records it.
run_report_phase() {
    local name="$1" start status
    shift
    start="$(run_report_now_ms)"
    printf '%s\t%s\n' "$name" "$start" > "$RUN_DIR/phase-open"
    "$@"
    status=$?
    run_report_close_phase "$status"
    return "$status"
}

# Records the open phase, if any, as ended now with the given status.
run_report_close_phase() {
    local name start
    [[ -f "$RUN_DIR/phase-open" ]] || return 0
    name="$(cut -f1 "$RUN_DIR/phase-open")"
    start="$(cut -f2 "$RUN_DIR/phase-open")"
    rm -f "$RUN_DIR/phase-open"
    printf '%s\t%s\t%s\t%s\n' "$name" "$start" "$(run_report_now_ms)" "$1" >> "$RUN_DIR/phases.tsv"
}

# The phase a run was in when it stopped: an interrupted phase, else the last one recorded.
run_report_reached() {
    if [[ -f "$RUN_DIR/phase-open" ]]; then
        cut -f1 "$RUN_DIR/phase-open"
    elif [[ -f "$RUN_DIR/phases.tsv" ]]; then
        tail -1 "$RUN_DIR/phases.tsv" | cut -f1
    fi
}

# run_report_classify <exit status> <reached phase> <suite started: true|false> <canceled: true|false>
run_report_classify() {
    local status="$1" suite_started="$3" canceled="$4"
    if [[ "$canceled" == true ]]; then
        echo canceled
    elif [[ "$status" == 0 ]]; then
        echo passed
    elif [[ "$suite_started" == true ]]; then
        echo failed
    else
        echo setup_failure
    fi
}

# run_report_source_identity <checkout>
# HEAD plus a digest of every uncommitted input: staged and unstaged edits, deletions and
# untracked files with their content. Two runs with equal identities tested the same source.
run_report_source_identity() {
    local checkout="$1" commit status digest dirty=false count
    commit="$(git -C "$checkout" rev-parse HEAD 2>/dev/null || echo unknown)"
    status="$(git -C "$checkout" status --porcelain=v1 --untracked-files=all 2>/dev/null || true)"
    if [[ -n "$status" ]]; then
        dirty=true
        count="$(printf '%s\n' "$status" | wc -l | tr -d ' ')"
        digest="$(
            {
                git -C "$checkout" diff HEAD --binary 2>/dev/null
                git -C "$checkout" ls-files --others --exclude-standard -z 2>/dev/null \
                    | while IFS= read -r -d '' path; do
                        printf '\n--- %s\n' "$path"
                        cat "$checkout/$path" 2>/dev/null || true
                    done
            } | shasum -a 256 | cut -d' ' -f1
        )"
        printf '{"commit": "%s", "dirty": true, "dirtyFiles": %s, "dirtyDigest": "%s"}\n' \
            "$commit" "$count" "$digest"
    else
        printf '{"commit": "%s", "dirty": %s}\n' "$commit" "$dirty"
    fi
}

# Seconds from ps's cumulative CPU time: M:SS.ss, H:MM:SS or D-HH:MM:SS.
run_report_ps_seconds() {
    echo "$1" | awk '{
        days = 0; value = $1
        if (index(value, "-") > 0) { split(value, d, "-"); days = d[1]; value = d[2] }
        n = split(value, p, ":"); total = 0
        for (i = 1; i <= n; i++) total = total * 60 + p[i]
        printf "%.1f\n", total + days * 86400
    }'
}

# CPU seconds used so far by the host processes that run guests. The queue allows one guest at
# a time, so these belong to this run; a guest restart resets them, so sample within a phase.
run_report_vm_cpu_seconds() {
    local total=0 time
    while read -r time; do
        [[ -n "$time" ]] || continue
        total="$(awk -v a="$total" -v b="$(run_report_ps_seconds "$time")" 'BEGIN { printf "%.1f", a + b }')"
    done < <(ps -axo time=,comm= | awk '/com\.apple\.Virtualization\.VirtualMachine|ParavirtualizedGraphicsGPUTask/ { print $1 }')
    echo "$total"
}

# Cumulative user+system CPU of this shell's finished children, from `times`, into
# RUN_REPORT_CPU. It must run in this shell: `times` inside $( ) reports the subshell's own
# children, which is none.
run_report_children_cpu_seconds() {
    local line
    times > "${TMPDIR:-/tmp}/debut-times.$$"
    line="$(tail -1 "${TMPDIR:-/tmp}/debut-times.$$")"
    rm -f "${TMPDIR:-/tmp}/debut-times.$$"
    RUN_REPORT_CPU="$(awk '{
        total = 0
        for (i = 1; i <= 2; i++) { split($i, p, "m"); sub("s", "", p[2]); total += p[1] * 60 + p[2] }
        printf "%.1f\n", total
    }' <<< "$line")"
}

# Bash runs a trap only after the foreground command returns, so a Ctrl-C during a four-minute
# guest session would wait for the whole session. Running the command in the background and
# waiting lets the trap fire at once; run_report_kill_children then ends what it started.
# The command keeps its own errexit behaviour, which an `if` or `||` around it would switch off.
RUN_REPORT_CHILD=""
run_report_interruptibly() {
    local status=0
    "$@" &
    RUN_REPORT_CHILD=$!
    wait "$RUN_REPORT_CHILD" || status=$?
    RUN_REPORT_CHILD=""
    return "$status"
}

run_report_kill_tree() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do
        run_report_kill_tree "$child"
    done
    kill -TERM "$1" 2>/dev/null || true
}

run_report_kill_children() {
    if [[ -n "$RUN_REPORT_CHILD" ]]; then
        run_report_kill_tree "$RUN_REPORT_CHILD"
        RUN_REPORT_CHILD=""
    fi
}

# run_report_write <run dir> <result> <source json> <selection json> <artifacts json> <cpu json>
run_report_write() {
    python3 - "$@" <<'PYEND'
import glob, json, os, sys

run_dir, result, source, selection, artifacts, cpu = sys.argv[1:7]

def phases(path, has_status):
    rows = []
    if not os.path.exists(path):
        return rows
    for line in open(path):
        fields = line.rstrip("\n").split("\t")
        if len(fields) < 3 or not fields[2]:
            continue
        row = {"name": fields[0], "seconds": round((int(fields[2]) - int(fields[1])) / 1000, 2)}
        if has_status and len(fields) > 3 and fields[3]:
            row["status"] = int(fields[3])
        rows.append(row)
    return rows

checks = {"passed": 0, "failed": 0, "skipped": 0, "failures": [], "invocations": []}
scenarios = {"ran": [], "not_selected": [], "setup_failed": []}
for path in sorted(glob.glob(os.path.join(run_dir, "results", "checks", "*.json"))):
    try:
        data = json.load(open(path))
    except (OSError, ValueError):
        continue
    checks["invocations"].append(data.get("invocation", os.path.basename(path)))
    for scenario in data.get("scenarios", []):
        scenarios.setdefault(scenario.get("status", "unknown"), []).append(
            f'{scenario.get("group", "")}/{scenario.get("id", "")}')
    for check in data.get("checks", []):
        status = check.get("status")
        if status in ("passed", "failed", "skipped"):
            checks[status] += 1
        if status == "failed":
            where = check.get("scenario") and f'{check.get("group")}/{check.get("scenario")}'
            checks["failures"].append(f'{where or check.get("section", "")}: {check.get("name", "")}')

report = {
    "schemaVersion": 1,
    "runID": os.path.basename(run_dir.rstrip("/")),
    "result": result,
    "source": json.loads(source),
    "selection": json.loads(selection),
    "artifacts": json.loads(artifacts),
    "cpu": json.loads(cpu),
    "hostPhases": phases(os.path.join(run_dir, "phases.tsv"), True),
    "guestPhases": phases(os.path.join(run_dir, "results", "guest-phases.tsv"), False),
    "checks": checks,
    "scenarios": scenarios,
}
with open(os.path.join(run_dir, "report.json"), "w") as handle:
    json.dump(report, handle, indent=2)
    handle.write("\n")
PYEND
}

run_report_summary() {
    python3 - "$1" <<'PYEND'
import json, os, sys
run_dir = sys.argv[1]
report = json.load(open(os.path.join(run_dir, "report.json")))
checks = report["checks"]
counted = checks["passed"] + checks["failed"] + checks["skipped"]
line = f'Tart E2E run {report["runID"]}: {report["result"]}'
if counted:
    line += f' ({checks["passed"]} passed, {checks["failed"]} failed, {checks["skipped"]} skipped)'
print(line)
print("  host:  " + "  ".join(f'{p["name"]} {p["seconds"]:.1f}s' for p in report["hostPhases"]))
if report["guestPhases"]:
    print("  guest: " + "  ".join(f'{p["name"]} {p["seconds"]:.1f}s' for p in report["guestPhases"]))
cpu = report.get("cpu", {})
if cpu:
    print("  cpu:   " + "  ".join(
        f"{k} {v if v is not None else 'unavailable'}" for k, v in cpu.items()
    ))
scenarios = report.get("scenarios", {})
if scenarios.get("ran") and scenarios.get("not_selected"):
    print(f'  scenarios: {len(scenarios["ran"])} ran, {len(scenarios["not_selected"])} not selected')
for scenario in scenarios.get("setup_failed", []):
    print(f"  SETUP FAILED  {scenario}")
for failure in checks["failures"]:
    print(f"  FAIL  {failure}")
print(f"  evidence: {run_dir}")
PYEND
}

# run_report_prune <runs dir> <keep> <active run dir>
# Keeps the newest <keep> runs and the newest <keep> unsuccessful ones. A directory without a
# report is either active or was killed mid-run; only the named active one is exempt.
run_report_prune() {
    local runs="$1" keep="$2" active="$3" run result index=0 failed_index=0
    [[ -d "$runs" ]] || return 0
    for run in $(ls -1 "$runs" | sort -r); do
        run="$runs/$run"
        [[ -d "$run" ]] || continue
        [[ "$run" == "$active" ]] && continue
        index=$(( index + 1 ))
        result="$(sed -n 's/.*"result": *"\([a-z_]*\)".*/\1/p' "$run/report.json" 2>/dev/null | head -1)"
        if [[ "$result" != passed ]]; then
            failed_index=$(( failed_index + 1 ))
            (( failed_index <= keep )) && continue
        fi
        (( index <= keep )) && continue
        rm -rf "$run"
    done
}
