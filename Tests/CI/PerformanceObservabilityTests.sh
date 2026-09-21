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
grep -q 'TelemetryDeck GmbH' docs/privacy.md
grep -q 'legitimate interest' docs/privacy.md
grep -q 'European Union' docs/privacy.md
grep -q '7–10 years' docs/privacy.md
grep -q 'right to object' docs/privacy.md
grep -q 'supervisory authority' docs/privacy.md
grep -q 'Disabling sharing' docs/privacy.md
! grep -q 'retention to at most 90 days' docs/privacy.md
! grep -q '90-day retention policy' docs/privacy-release-checklist.md
/usr/bin/plutil -extract NSPrivacyTracking raw -o - Resources/PrivacyInfo.xcprivacy | grep -qx false
grep -q 'PrivacyInfo.xcprivacy' scripts/build-app.sh
grep -q 'DEBUT_PERFORMANCE_PROFILE' Sources/DebutPerformanceFixture/main.swift
grep -q 'preview-50' scripts/tart-performance-guest.sh
grep -q 'overlay-end-to-end-visible' scripts/tart-performance-guest.sh
grep -q 'overlay-render-submission' scripts/tart-performance-guest.sh
! grep -q 'overlay-first-frame' scripts/tart-performance-guest.sh
grep -q 'name: "DebutInputDriver"' Package.swift
grep -q 'drive-stage-cycle' Sources/DebutPerformanceFixture/main.swift
grep -q 'drive-stage-cycle' scripts/tart-performance-guest.sh
grep -q 'sample-stage-cycle' scripts/tart-performance-guest.sh
# `tart exec` makes tart-guest-agent the TCC-responsible process, so WindowServer
# rejects every synthesized event with "Sender is prohibited from synthesizing
# events" no matter how the fixture is granted. The guest script must run over SSH.
grep -q 'ssh -i' scripts/tart-performance.sh
! grep -q 'tart exec .*tart-performance-guest' scripts/tart-performance.sh

echo "Performance observability repository contract passed."
