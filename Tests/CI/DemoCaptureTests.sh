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

# README and onboarding media use the site's nine-window fixture (KHA-1119): two separate Apple
# Notes windows, never TextEdit documents, and the site's offline Safari pages.
if grep -q 'open -a TextEdit\|\.rtf' "$guest"; then
    fail "$guest still opens the retired TextEdit fixture"
fi
for title in "Reading list" "Project notes"; do
    grep -q "show note \"$title\" of fixtureFolder with separately" "$guest" \
        || fail "$guest must open the $title note in its own Notes window"
done
grep -q 'grant kTCCServiceAppleEvents "$client" 1 "$client" com.apple.Notes' "$guest" \
    || fail "$guest must let the guest script drive Notes"
for page in index.html:"Field Notes" 04-spaces.html:"Weekend Guide"; do
    grep -q "<title>${page#*:}</title>" "Tests/Fixtures/Demo/html/${page%%:*}" \
        || fail "Tests/Fixtures/Demo/html/${page%%:*} is not the ${page#*:} fixture page"
done
if grep -rq 'com.apple.TextEdit' Sources/DebutDemo; then
    fail "the demo driver still refers to the retired TextEdit fixture"
fi

if (( failures > 0 )); then
    echo "$failures demo capture contract check(s) failed" >&2
    exit 1
fi
echo "Demo capture contracts passed"
