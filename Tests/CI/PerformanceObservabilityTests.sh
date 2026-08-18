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
grep -q 'overlay-end-to-end-visible' scripts/tart-performance-guest.sh
grep -q 'overlay-render-submission' scripts/tart-performance-guest.sh
! grep -q 'overlay-first-frame' scripts/tart-performance-guest.sh
grep -q 'name: "DebutInputDriver"' Package.swift
grep -q 'drive-plate-cycle' Sources/DebutPerformanceFixture/main.swift
grep -q 'drive-plate-cycle' scripts/tart-performance-guest.sh
grep -q 'sample-plate-cycle' scripts/tart-performance-guest.sh
# `tart exec` makes tart-guest-agent the TCC-responsible process, so WindowServer
# rejects every synthesized event with "Sender is prohibited from synthesizing
# events" no matter how the fixture is granted. The guest script must run over SSH.
grep -q 'ssh -i' scripts/tart-performance.sh
! grep -q 'tart exec .*tart-performance-guest' scripts/tart-performance.sh

echo "Performance observability repository contract passed."
