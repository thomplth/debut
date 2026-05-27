#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

pkill -f "Debut.app" 2>/dev/null || true
sleep 1

echo "Building..."
./scripts/build-app.sh

echo "Installing..."
rm -rf /Applications/Debut.app
cp -R .build/Debut.app /Applications/Debut.app

echo "Launching..."
open /Applications/Debut.app
sleep 3

echo "Running E2E tests..."
./scripts/e2e-test.sh
