#!/bin/bash
set -euo pipefail

# Crash reports leave the Mac only from release builds that were given a destination, and the
# privacy disclosures must describe exactly that.
cd "$(dirname "$0")/../.."

failures=0
fail() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

action=".github/actions/publish-release/action.yml"

# Every build reports to the one Debut project, so the destination is committed rather than
# stamped by one workflow; a build without it would silently report nothing.
dsn="$(/usr/bin/plutil -extract DebutCrashReportDSN raw -o - Resources/Info.plist 2>/dev/null || true)"
[[ "$dsn" =~ ^https://[0-9a-f]+@[^/]+\.sentry\.io/[0-9]+$ ]] \
    || fail "Resources/Info.plist must carry the Debut project's DebutCrashReportDSN (got '$dsn')"
grep -q 'dsnInfoKey = "DebutCrashReportDSN"' Sources/DebutApp/SentryCrashReporter.swift \
    || fail "the reporter must read the key Info.plist carries"
if grep -Rq 'DEBUT_CRASH_REPORT_DSN' scripts .github; then
    fail "no build may substitute its own destination"
fi
grep -q 'dsymutil' scripts/build-app.sh \
    || fail "build-app.sh must produce a dSYM so crash reports can be symbolicated"
grep -q 'Debut.dSYM.zip' "$action" \
    || fail "every release must archive its dSYM"

# Nothing may leave the Mac without consent beyond the error events themselves.
reporter="Sources/DebutApp/SentryCrashReporter.swift"
for option in 'sendDefaultPii = false' 'sendClientReports = false' \
    'enableAutoSessionTracking = false' 'enableAutoBreadcrumbTracking = false' \
    'enableAutoPerformanceTracing = false' 'enableCaptureFailedRequests = false'; do
    grep -q "options.$option" "$reporter" || fail "Sentry must be configured with $option"
done

manifest="Resources/PrivacyInfo.xcprivacy"
/usr/bin/plutil -extract NSPrivacyTracking raw -o - "$manifest" | grep -qx false \
    || fail "crash reports must not be declared as tracking"
for index in 0 1; do
    type="$(/usr/bin/plutil -extract "NSPrivacyCollectedDataTypes.$index.NSPrivacyCollectedDataType" raw -o - "$manifest" 2>/dev/null || true)"
    linked="$(/usr/bin/plutil -extract "NSPrivacyCollectedDataTypes.$index.NSPrivacyCollectedDataTypeLinked" raw -o - "$manifest" 2>/dev/null || true)"
    case "$type" in
        NSPrivacyCollectedDataTypeCrashData|NSPrivacyCollectedDataTypePerformanceData) ;;
        *) fail "the privacy manifest must declare crash and performance data (entry $index: '$type')" ;;
    esac
    [[ "$linked" == false ]] || fail "$type must be declared as not linked to the user"
done

# Development builds (local installs, E2E, Tart, CI, source builds and forks) carry the DSN but
# must never report: a crash prompt would block a test VM, and unsymbolicated dev crashes are noise.
grep -q 'CrashReportEnvironment.reportsCrashes' Sources/DebutApp/SentryCrashReporter.swift \
    || fail "the reporter must stay unavailable in development builds"
grep -q 'CrashReportEnvironment.name' Sources/DebutApp/SentryCrashReporter.swift \
    || fail "the reporter must tag each build's Sentry environment"

grep -q 'Sentry' docs/privacy.md || fail "the privacy notice must name Sentry"
grep -q 'Send crash reports automatically' docs/privacy.md \
    || fail "the privacy notice must name the Settings control"

if (( failures > 0 )); then
    exit 1
fi
echo "PASS: crash reporting contract"
