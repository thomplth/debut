#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_DIR"

fail() { echo "FAIL: $1" >&2; exit 1; }

test -x scripts/health-report.py || fail "health report is executable"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

stamp() { date -u -v-"$1"M +%Y-%m-%dT%H:%M:%SZ; }

cat > "$WORK/healthy.jsonl" <<JSON
{"event":"launch_ready","milliseconds":"420.0","timestamp":"$(stamp 600)"}
{"event":"health_rollup","kind":"active","intervalSeconds":"3600.0","cpuMilliseconds":"7200.0","cpuPercent":"0.200","energyMillijoules":"18000.0","milliwatts":"5.00","gpuMillijoules":"1800000.0","footprintMegabytes":"160.0","peakFootprintMegabytes":"210.0","processAgeSeconds":"3700.0","timestamp":"$(stamp 500)"}
{"event":"health_rollup","kind":"idle","intervalSeconds":"7200.0","cpuMilliseconds":"720.0","cpuPercent":"0.010","energyMillijoules":"720.0","milliwatts":"0.10","footprintMegabytes":"160.0","peakFootprintMegabytes":"210.0","processAgeSeconds":"10900.0","timestamp":"$(stamp 400)"}
{"event":"overlay_session_cost","visibleMilliseconds":"2000.0","cpuMilliseconds":"300.0","energyMillijoules":"400.0","gpuMillijoules":"1400.0","pressToRevealMilliseconds":"140.0","holdDelayMilliseconds":"100.0","inputLatencyMilliseconds":"0.4","frames":"240","slowFrames":"1","longestFrameMilliseconds":"20.0","refreshMilliseconds":"8.3","timestamp":"$(stamp 300)"}
{"event":"focus_commit_settled","crossesDesktop":"false","outcome":"focused","focusedMilliseconds":"120.0","timestamp":"$(stamp 200)"}
{"event":"focus_commit_settled","crossesDesktop":"true","outcome":"focused","focusedMilliseconds":"60.0","desktopChangedMilliseconds":"420.0","timestamp":"$(stamp 190)"}
{"event":"focus_commit_settled","crossesDesktop":"false","outcome":"superseded","timestamp":"$(stamp 185)"}
{"event":"preview_freshness","visibleChanges":"0","timestamp":"$(stamp 180)"}
{"event":"window_front_outcome","windowID":"5","recovered":"true","recoveredMilliseconds":"300.0","timestamp":"$(stamp 170)"}
JSON

output="$(scripts/health-report.py --file "$WORK/healthy.jsonl")" || fail "a healthy log passes: $output"
for goal in R1 R2 R3 R4 R5 R6 C1 C2 C3 P1 P2 P3 P4 P5; do
    grep -Eq "^pass +$goal " <<<"$output" || fail "goal $goal passes on a healthy log: $output"
done
grep -q "+0.20 W over a 0.50 W baseline" <<<"$output" || fail "GPU added power subtracts the active baseline: $output"
grep -q "growth unmeasured" <<<"$output" || fail "growth needs a launch that ran six hours: $output"

cp "$WORK/healthy.jsonl" "$WORK/stalled.jsonl"
echo "{\"event\":\"main_run_loop_stalled\",\"milliseconds\":\"276.4\",\"overlayVisible\":\"true\",\"timestamp\":\"$(stamp 100)\"}" >> "$WORK/stalled.jsonl"
echo "{\"event\":\"window_front_outcome\",\"windowID\":\"6\",\"recovered\":\"false\",\"timestamp\":\"$(stamp 90)\"}" >> "$WORK/stalled.jsonl"
if output="$(scripts/health-report.py --file "$WORK/stalled.jsonl")"; then fail "a stall fails the report"; fi
grep -Eq "^FAIL +R3 .*longest 276 ms" <<<"$output" || fail "the stall is named: $output"
grep -Eq "^FAIL +C2 .*1 in" <<<"$output" || fail "the unrecovered front is counted: $output"

echo "{\"event\":\"health_rollup\",\"kind\":\"idle\",\"intervalSeconds\":\"60\",\"timestamp\":\"2020-01-01T00:00:00Z\"}" > "$WORK/old.jsonl"
output="$(scripts/health-report.py --file "$WORK/old.jsonl" --days 7)" || fail "an empty window is not a failure"
grep -Eq "^no data +P1 " <<<"$output" || fail "lines older than the window are ignored: $output"

if scripts/health-report.py --file "$WORK/missing.jsonl" 2>/dev/null; then fail "a missing log is an error"; fi

echo "Health report contract passed."
