#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="${DEBUT_PERFORMANCE_RESULTS:-$PROJECT_DIR/.build/performance-results}"
mkdir -p "$RESULTS_DIR"

cd "$PROJECT_DIR"
TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault /usr/bin/swift build -c release --product DebutBenchmarks
artifact="$RESULTS_DIR/benchmarks-$(date -u +%Y%m%dT%H%M%SZ).json"
"$PROJECT_DIR/.build/release/DebutBenchmarks" > "$artifact"
/usr/bin/jq -e . "$artifact" >/dev/null
cp "$artifact" "$RESULTS_DIR/benchmarks-latest.json"
"$PROJECT_DIR/scripts/check-performance-regression.sh" "$PROJECT_DIR/PerformanceBudgets.json" "$artifact"
echo "Benchmark artifact: $artifact"
