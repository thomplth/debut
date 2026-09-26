#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

export TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault

# The suite injects global input and quits apps in whatever session runs it. Use the headless
# Tart VM (scripts/tart-e2e.sh run); this script is only for a session you are willing to lose.
if [[ "${DEBUT_E2E_DISPOSABLE_SESSION:-}" != 1 ]]; then
    echo "Refusing to drive this session. Run scripts/tart-e2e.sh run, or set" >&2
    echo "DEBUT_E2E_DISPOSABLE_SESSION=1 if this session is disposable." >&2
    exit 2
fi

echo "Ensuring Debut is running..."
if ! pgrep -f "Debut.app" > /dev/null 2>&1; then
    open /Applications/Debut.app
    sleep 3
fi

echo "Building and running E2E tests..."
/usr/bin/swift run DebutE2E
