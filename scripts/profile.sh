#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_PATH="/Applications/Debut.app"
RESULTS_DIR="${DEBUT_PROFILE_RESULTS:-$PROJECT_DIR/.build/profile-results}"
COMMAND="${1:-help}"
TEMPLATE="${2:-Time Profiler}"

usage() {
    cat <<'EOF'
Usage: scripts/profile.sh <record|triage|templates> [template]

Templates: Time Profiler, SwiftUI, Animation Hitches, Allocations, Leaks,
System Trace, Swift Concurrency, App Launch.
EOF
}

mkdir -p "$RESULTS_DIR"
case "$COMMAND" in
    record)
        test -x "$APP_PATH/Contents/MacOS/Debut"
        output="$RESULTS_DIR/$(tr ' ' '-' <<< "$TEMPLATE")-$(date -u +%Y%m%dT%H%M%SZ).trace"
        xcrun xctrace record --template "$TEMPLATE" --output "$output" --launch "$APP_PATH/Contents/MacOS/Debut"
        echo "Trace: $output"
        ;;
    triage)
        pid="$(pgrep -f '/Applications/Debut.app/Contents/MacOS/Debut' | head -1)"
        ps -p "$pid" -o pid,%cpu,%mem,rss,vsz,threads,time,command > "$RESULTS_DIR/ps.txt"
        sample "$pid" 5 -file "$RESULTS_DIR/sample.txt"
        vmmap "$pid" > "$RESULTS_DIR/vmmap.txt"
        heap "$pid" > "$RESULTS_DIR/heap.txt"
        leaks "$pid" > "$RESULTS_DIR/leaks.txt" || true
        echo "Triage evidence: $RESULTS_DIR"
        ;;
    templates) xcrun xctrace list templates ;;
    *) usage ;;
esac
