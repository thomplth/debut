#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

failures=0
fail() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

guest="scripts/demo-capture-guest.sh"
[[ -f "$guest" ]] || { echo "FAIL: missing $guest" >&2; exit 1; }

# Captures start from Debut's fresh defaults (KHA-1117). Appearance belongs to the app; the
# guest must not write its own settings file, and the driver writes only fixture deltas.
if grep -q 'settings.json' "$guest"; then
    fail "$guest writes Debut's settings itself; let the driver encode AppSettings()"
fi
for key in glassStyle stageScale stageCornerRadius inactiveStageScale; do
    if grep -q "$key" "$guest"; then
        fail "$guest hard-codes the capture appearance ($key)"
    fi
    if grep -rq "$key" Sources/DebutDemo; then
        fail "the demo driver overrides the default appearance ($key)"
    fi
done
grep -q -- '--reset-settings' "$guest" \
    || fail "$guest must reset Debut to the driver's fresh capture settings"
if grep -rq 'previewAppearance\|iconAppearance' Sources/DebutDemo; then
    fail "the demo driver overrides a per-mode appearance"
fi

if (( failures > 0 )); then
    echo "$failures demo capture contract check(s) failed" >&2
    exit 1
fi
echo "Demo capture contracts passed"
