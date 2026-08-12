#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_DIR"

grep -q 'name: "DebutPerformanceFixture"' Package.swift
grep -q 'name: "DebutBenchmarks"' Package.swift
test -x scripts/performance-test.sh
test -x scripts/tart-performance.sh
test -x scripts/profile.sh
test -x scripts/check-performance-regression.sh
test -f PerformanceBudgets.json
grep -q 'typical.*4.*12.*4' docs/performance-observability.md
grep -q 'p95' docs/performance-observability.md
grep -q 'window titles' docs/privacy.md
/usr/bin/plutil -extract NSPrivacyTracking raw -o - Resources/PrivacyInfo.xcprivacy | grep -qx false
grep -q 'PrivacyInfo.xcprivacy' scripts/build-app.sh
grep -q 'DEBUT_PERFORMANCE_PROFILE' Sources/DebutPerformanceFixture/main.swift
grep -q 'preview-50' scripts/tart-performance-guest.sh

echo "Performance observability repository contract passed."
