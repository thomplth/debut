#!/bin/bash
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true ]] || {
    echo 'Use tart-update-e2e.sh for local update validation.' >&2; exit 1;
}
cd "$(dirname "$0")/.."
channel="${1:?missing update channel}"
previous="${2:-}"
build="${3:?missing build version}"
case "$channel" in
    stable)
        [[ -n "$previous" ]] || {
            echo 'A previous signed stable release is required for the update gate.' >&2
            exit 1
        }
        ;;
    nightly)
        if [[ -z "$previous" ]]; then
            echo 'No compatible nightly exists yet; this release bootstraps the isolated nightly feed.'
            exit 0
        fi
        ;;
    *) echo "Unknown update channel: $channel" >&2; exit 1 ;;
esac
fixture="$RUNNER_TEMP/update-e2e"
mkdir -p "$RUNNER_TEMP/update-baseline"
gh release download "$previous" --repo "$GITHUB_REPOSITORY" --pattern Debut.dmg --dir "$RUNNER_TEMP/update-baseline"
./scripts/prepare-update-e2e.sh "$RUNNER_TEMP/update-baseline/Debut.dmg" .build/Debut.dmg .build/appcast.xml "$fixture"
./scripts/update-e2e-guest.sh "$fixture" "$build"
