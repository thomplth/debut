#!/bin/bash
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true ]] || {
    echo 'Use tart-update-e2e.sh for local update validation.' >&2; exit 1;
}
cd "$(dirname "$0")/.."
previous="${1:?A previous signed stable release is required for the update gate}"
build="${2:?missing build version}"
fixture="$RUNNER_TEMP/update-e2e"
mkdir -p "$RUNNER_TEMP/update-baseline"
gh release download "$previous" --repo "$GITHUB_REPOSITORY" --pattern Debut.dmg --dir "$RUNNER_TEMP/update-baseline"
./scripts/prepare-update-e2e.sh "$RUNNER_TEMP/update-baseline/Debut.dmg" .build/Debut.dmg .build/appcast.xml "$fixture"
./scripts/update-e2e-guest.sh "$fixture" "$build"
