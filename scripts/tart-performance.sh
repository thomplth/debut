#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VM_NAME="${DEBUT_TART_VM:-debut-e2e-tahoe}"
SHARE_DIR="${DEBUT_TART_SHARE:-$HOME/Library/Caches/Debut/TartE2E}"
PROFILE="${2:-typical}"

case "$PROFILE" in typical|busy|stress) ;; *) echo "Profile must be typical, busy, or stress" >&2; exit 2 ;; esac
case "${1:-}" in
    run) ;;
    *) echo "Usage: scripts/tart-performance.sh run [typical|busy|stress]" >&2; exit 2 ;;
esac

command -v tart >/dev/null || { echo "Tart is required" >&2; exit 1; }
tart list --source local --quiet | grep -Fqx "$VM_NAME" || { echo "Prepare $VM_NAME with scripts/tart-e2e.sh prepare" >&2; exit 1; }

"$PROJECT_DIR/scripts/build-app.sh"
TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault /usr/bin/swift build -c release --product DebutPerformanceFixture
mkdir -p "$SHARE_DIR"
artifact_id="$(date +%s)-$$"
/usr/bin/ditto -c -k --keepParent "$PROJECT_DIR/.build/Debut.app" "$SHARE_DIR/Debut-performance-$artifact_id.app.zip"
/usr/bin/install -m 755 "$PROJECT_DIR/.build/release/DebutPerformanceFixture" "$SHARE_DIR/DebutPerformanceFixture-$artifact_id"
/usr/bin/install -m 755 "$PROJECT_DIR/scripts/tart-performance-guest.sh" "$SHARE_DIR/tart-performance-guest-$artifact_id.sh"

if ! tart exec "$VM_NAME" /usr/bin/true >/dev/null 2>&1; then
    nohup tart run --no-graphics --no-audio --no-clipboard --no-pointer --no-keyboard --dir="$SHARE_DIR" "$VM_NAME" > "$SHARE_DIR/tart-performance-vm.log" 2>&1 </dev/null &
    for _ in {1..90}; do tart exec "$VM_NAME" /usr/bin/true >/dev/null 2>&1 && break; sleep 2; done
fi

tart exec "$VM_NAME" /bin/bash "/Volumes/My Shared Files/tart-performance-guest-$artifact_id.sh" \
    "Debut-performance-$artifact_id.app.zip" "DebutPerformanceFixture-$artifact_id" "$PROFILE"
echo "Performance evidence: $SHARE_DIR/performance-results"
