#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

export TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault

echo "Ensuring Debut is running..."
if ! pgrep -f "Debut.app" > /dev/null 2>&1; then
    open /Applications/Debut.app
    sleep 3
fi

echo "Building and running E2E tests..."
/usr/bin/swift run DebutE2E
