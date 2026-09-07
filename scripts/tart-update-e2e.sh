#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
baseline="${1:?usage: tart-update-e2e.sh <baseline.dmg> <candidate.dmg> <appcast.xml> <build-version>}"
candidate="${2:?missing candidate}"
appcast="${3:?missing appcast}"
build="${4:?missing build}"
vm="${DEBUT_UPDATE_VM:-debut-update-tahoe}"
share="${DEBUT_UPDATE_SHARE:-$HOME/Library/Caches/Debut/TartUpdate}"
if ! tart list --source local --quiet | grep -Fxq "$vm"; then
    echo "Prepare a separate update VM with: tart clone debut-e2e-tahoe $vm" >&2
    exit 1
fi
mkdir -p "$share"
if tart exec "$vm" /usr/bin/true >/dev/null 2>&1; then tart stop "$vm"; fi
"$root/scripts/prepare-update-e2e.sh" "$baseline" "$candidate" "$appcast" "$share"
touch "$share/.debut-update-fixture"
nohup tart run --no-graphics --no-audio --no-clipboard --no-pointer --no-keyboard --dir="$share" "$vm" >"$share/vm.log" 2>&1 </dev/null &
trap 'tart stop "$vm" >/dev/null 2>&1 || true' EXIT
for _ in {1..90}; do
    if tart exec "$vm" /usr/bin/true >/dev/null 2>&1; then break; fi
    sleep 2
done
tart exec "$vm" /bin/bash '/Volumes/My Shared Files/guest.sh' '/Volumes/My Shared Files' "$build" 2>&1 | tee "$share/update.log"
echo "Update evidence: $share/evidence"
