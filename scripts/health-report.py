#!/usr/bin/env python3
"""Judge a development build against Debut's absolute health goals.

Reads the retained lines a development build appends to health.jsonl, which never rotates,
and prints each goal with its measured value. Exits 1 when any measured goal fails.
"""
import argparse
import datetime
import json
import math
import os
import statistics
import sys

DEFAULT_FILE = os.path.expanduser("~/Library/Application Support/Debut/health.jsonl")


def load(path, days):
    cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)
    events = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            try:
                event = json.loads(line)
                stamp = datetime.datetime.fromisoformat(event["timestamp"].replace("Z", "+00:00"))
            except (ValueError, KeyError):
                continue
            if stamp >= cutoff:
                event["_time"] = stamp
                events.append(event)
    return events


def number(event, key):
    value = event.get(key)
    return float(value) if value not in (None, "") else None


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, max(0, math.ceil(fraction * len(ordered)) - 1))]


def of(events, name):
    return [event for event in events if event.get("event") == name]


def judge(events):
    results = []

    def add(goal, target, measured, passed):
        results.append((goal, target, measured, "no data" if passed is None else ("pass" if passed else "FAIL")))

    span_days = 0.0
    if events:
        span_days = max(
            (events[-1]["_time"] - events[0]["_time"]).total_seconds() / 86_400, 1 / 24
        )

    sessions = of(events, "overlay_session_cost")
    beyond = [
        number(s, "pressToRevealMilliseconds") - number(s, "holdDelayMilliseconds")
        for s in sessions
        if number(s, "pressToRevealMilliseconds") is not None and number(s, "holdDelayMilliseconds") is not None
    ]
    add("R1 press to visible beyond the hold delay", "p99 <= 60 ms",
        f"p99 {percentile(beyond, .99):.0f} ms (n={len(beyond)})" if beyond else "-",
        percentile(beyond, .99) <= 60 if beyond else None)

    inputs = [v for v in (number(s, "inputLatencyMilliseconds") for s in sessions) if v is not None]
    add("R2 event tap to main queue", "p99 <= 5 ms",
        f"p99 {percentile(inputs, .99):.1f} ms (n={len(inputs)})" if inputs else "-",
        percentile(inputs, .99) <= 5 if inputs else None)

    stalls = [number(s, "milliseconds") for s in of(events, "main_run_loop_stalled")]
    add("R3 main run-loop stalls over 100 ms", "0 per day",
        (f"{len(stalls)} in {span_days:.1f} days" + (f", longest {max(stalls):.0f} ms" if stalls else ""))
        if events else "-",
        len(stalls) == 0 if events else None)

    commits = [c for c in of(events, "focus_commit_settled") if c.get("outcome") != "superseded"]
    same = [c for c in commits if c.get("crossesDesktop") == "false"]
    same_ms = [number(c, "focusedMilliseconds") if c.get("outcome") == "focused" else math.inf for c in same]
    add("R4 commit to focus, same desktop", "p90 <= 150 ms, max <= 250 ms",
        f"p90 {percentile(same_ms, .9):.0f} ms, max {max(same_ms):.0f} ms (n={len(same_ms)})" if same_ms else "-",
        (percentile(same_ms, .9) <= 150 and max(same_ms) <= 250) if same_ms else None)

    cross = [c for c in commits if c.get("crossesDesktop") == "true"]
    after_arrival = []
    for commit in cross:
        focused = number(commit, "focusedMilliseconds")
        arrived = number(commit, "desktopChangedMilliseconds")
        if commit.get("outcome") != "focused" or focused is None or arrived is None:
            after_arrival.append(math.inf)
        else:
            after_arrival.append(max(focused, arrived) - arrived)
    arrivals = [number(c, "desktopChangedMilliseconds") for c in cross if number(c, "desktopChangedMilliseconds") is not None]
    add("R5 focus after the desktop arrives", "p90 <= 100 ms",
        (f"p90 {percentile(after_arrival, .9):.0f} ms (n={len(after_arrival)})"
         + (f"; desktop arrival p50 {percentile(arrivals, .5):.0f} ms" if arrivals else ""))
        if after_arrival else "-",
        percentile(after_arrival, .9) <= 100 if after_arrival else None)

    launches = [number(l, "milliseconds") for l in of(events, "launch_ready")]
    add("R6 launch to ready", "p90 <= 1000 ms",
        f"p90 {percentile(launches, .9):.0f} ms (n={len(launches)})" if launches else "-",
        percentile(launches, .9) <= 1000 if launches else None)

    freshness = [f for f in of(events, "preview_freshness") if f.get("visibleChanges") is not None]
    visible = sum(1 for f in freshness if int(f["visibleChanges"]) > 0)
    add("C1 reveals with a visible change after the reveal", "<= 2%",
        f"{visible / len(freshness):.1%} ({visible}/{len(freshness)})" if freshness else "-",
        visible / len(freshness) <= 0.02 if freshness else None)

    fronts = of(events, "window_front_outcome")
    unrecovered = sum(1 for f in fronts if f.get("recovered") == "false")
    add("C2 windows that never took the front", "0 per day",
        f"{unrecovered} in {span_days:.1f} days ({len(fronts) - unrecovered} recovered)" if events else "-",
        unrecovered == 0 if events else None)

    frames = sum(int(s["frames"]) for s in sessions if s.get("frames"))
    slow = sum(int(s["slowFrames"]) for s in sessions if s.get("slowFrames"))
    add("C3 overlay frames over 1.5x the refresh interval", "<= 1%",
        f"{slow / frames:.2%} ({slow}/{frames})" if frames else "-",
        slow / frames <= 0.01 if frames else None)

    rollups = of(events, "health_rollup")
    idle = [r for r in rollups if r.get("kind") == "idle"]
    idle_seconds = sum(number(r, "intervalSeconds") for r in idle)
    if idle_seconds > 0:
        idle_cpu = sum(number(r, "cpuMilliseconds") for r in idle) / 1000 / idle_seconds * 100
        idle_mw = sum(number(r, "energyMillijoules") for r in idle) / idle_seconds
        add("P1 idle", "<= 0.05% core, <= 0.5 mW",
            f"{idle_cpu:.3f}% core, {idle_mw:.2f} mW over {idle_seconds / 3600:.1f} h",
            idle_cpu <= 0.05 and idle_mw <= 0.5)
    else:
        add("P1 idle", "<= 0.05% core, <= 0.5 mW", "-", None)

    active = [r for r in rollups if r.get("kind") == "active"]
    long_active = [r for r in active if number(r, "intervalSeconds") >= 900]
    if long_active:
        peak_cpu = max(number(r, "cpuPercent") for r in long_active)
        peak_mw = max(number(r, "milliwatts") for r in long_active)
        add("P2 heaviest active interval (15 min or longer)", "<= 1% core, <= 20 mW",
            f"{peak_cpu:.2f}% core, {peak_mw:.1f} mW (n={len(long_active)})",
            peak_cpu <= 1 and peak_mw <= 20)
    else:
        add("P2 heaviest active interval (15 min or longer)", "<= 1% core, <= 20 mW", "-", None)

    energies = [number(s, "energyMillijoules") for s in sessions]
    add("P3 Debut CPU energy per reveal", "mean <= 1 J",
        f"mean {statistics.fmean(energies) / 1000:.2f} J (n={len(energies)})" if energies else "-",
        statistics.fmean(energies) <= 1000 if energies else None)

    gpu_sessions = [s for s in sessions if s.get("gpuMillijoules")]
    gpu_active = [r for r in active if r.get("gpuMillijoules")]
    visible_seconds = sum(number(s, "visibleMilliseconds") for s in gpu_sessions) / 1000
    active_seconds = sum(number(r, "intervalSeconds") for r in gpu_active)
    if visible_seconds > 0 and active_seconds > visible_seconds:
        session_joules = sum(number(s, "gpuMillijoules") for s in gpu_sessions) / 1000
        baseline = (sum(number(r, "gpuMillijoules") for r in gpu_active) / 1000 - session_joules) / (
            active_seconds - visible_seconds
        )
        added = session_joules / visible_seconds - baseline
        add("P4 GPU power added while the overlay is up", "<= 0.3 W",
            f"{added:+.2f} W over a {baseline:.2f} W baseline ({visible_seconds:.0f} s visible)",
            added <= 0.3)
    else:
        add("P4 GPU power added while the overlay is up", "<= 0.3 W", "-", None)

    settled = [r for r in rollups if (number(r, "processAgeSeconds") or 0) >= 3600]
    if settled:
        steady = statistics.median(number(r, "footprintMegabytes") for r in settled)
        peak = max(number(r, "peakFootprintMegabytes") for r in rollups)
        growth = footprint_growth(rollups)
        add("P5 memory footprint", "steady <= 200 MB, peak <= 250 MB, growth <= 10 MB/day",
            f"steady {steady:.0f} MB, peak {peak:.0f} MB, growth "
            + (f"{growth:+.1f} MB/day" if growth is not None else "unmeasured (no launch ran 6 h)"),
            steady <= 200 and peak <= 250 and (growth is None or growth <= 10))
    else:
        add("P5 memory footprint", "steady <= 200 MB, peak <= 250 MB, growth <= 10 MB/day", "-", None)
    return results


def footprint_growth(rollups):
    """The steepest least-squares slope across any one launch that ran six hours or more."""
    launches, current, previous_age = [], [], -1.0
    for rollup in rollups:
        age = number(rollup, "processAgeSeconds")
        if age is None:
            continue
        if age < previous_age:
            launches.append(current)
            current = []
        current.append((age, number(rollup, "footprintMegabytes")))
        previous_age = age
    launches.append(current)
    slopes = []
    for points in launches:
        if len(points) < 3 or points[-1][0] - points[0][0] < 6 * 3600:
            continue
        mean_age = statistics.fmean(p[0] for p in points)
        mean_size = statistics.fmean(p[1] for p in points)
        spread = sum((p[0] - mean_age) ** 2 for p in points)
        slopes.append(sum((p[0] - mean_age) * (p[1] - mean_size) for p in points) / spread * 86_400)
    return max(slopes) if slopes else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", default=DEFAULT_FILE)
    parser.add_argument("--days", type=float, default=7)
    args = parser.parse_args()
    if not os.path.exists(args.file):
        print(f"No health log at {args.file}; only development builds write one.", file=sys.stderr)
        return 2
    events = load(args.file, args.days)
    results = judge(events)
    widths = [max(len(row[i]) for row in results) for i in range(3)]
    print(f"Debut health, last {args.days:g} days ({len(events)} lines)")
    for goal, target, measured, verdict in results:
        print(f"{verdict:<8} {goal:<{widths[0]}}  {target:<{widths[1]}}  {measured}")
    return 1 if any(row[3] == "FAIL" for row in results) else 0


if __name__ == "__main__":
    sys.exit(main())
