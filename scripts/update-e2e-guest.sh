#!/bin/bash
set -euo pipefail
# Only the disposable Tart VM or GitHub release runner may replace this app.
if [[ "${GITHUB_ACTIONS:-}" != true ]] && { [[ ! -f '/Volumes/My Shared Files/.debut-update-fixture' ]] || [[ "$(sysctl -n kern.hv_vmm_present)" != 1 ]]; }; then
    echo 'Update E2E is restricted to disposable hosts; use tart-update-e2e.sh.' >&2
    exit 1
fi
fixture="${1:?missing fixture directory}"
expected="${2:?missing expected build}"
app=/Applications/Debut.app
mount="$(mktemp -d)"
server_pid=''
cleanup() {
    [[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true
    hdiutil detach "$mount" -quiet 2>/dev/null || true
    rmdir "$mount" 2>/dev/null || true
    defaults delete com.thomplth.Debut SUFeedURL 2>/dev/null || true
    pkill -x Debut 2>/dev/null || true
}
trap cleanup EXIT
mkdir -p "$fixture/evidence"
pkill -x Debut 2>/dev/null || true
hdiutil attach "$fixture/baseline.dmg" -readonly -nobrowse -mountpoint "$mount" -quiet
sudo rm -rf "$app"
sudo ditto "$mount/Debut.app" "$app"
hdiutil detach "$mount" -quiet

# Register the actual signatures of the published app and AX driver in this
# disposable host's TCC database. Do not re-sign either release fixture.
for pair in "$app:com.thomplth.Debut:0" "$fixture/update-driver:$fixture/update-driver:1"; do
    signed_path="${pair%%:*}"; rest="${pair#*:}"; client="${rest%:*}"; type="${rest##*:}"
    requirement="$(codesign -d -r- "$signed_path" 2>&1 | awk -F ' => ' '/designated/{print $2}')"
    hex="$(printf '%s' "$requirement" | csreq -r- -b /dev/stdout | xxd -p | tr -d '\n')"
    timestamp="$(date +%s)"
    sudo sqlite3 '/Library/Application Support/com.apple.TCC/TCC.db' "INSERT OR REPLACE INTO access VALUES('kTCCServiceAccessibility','$client',$type,2,4,1,X'$hex',NULL,0,'UNUSED',NULL,0,$timestamp,NULL,NULL,'UNUSED',$timestamp);"
done
sudo killall tccd 2>/dev/null || true
rm -rf "$HOME/Library/Application Support/Debut"
defaults write com.thomplth.Debut hasCompletedOnboarding -bool true
defaults write com.thomplth.Debut SUFeedURL -string http://127.0.0.1:18765/appcast.xml
defaults write com.thomplth.Debut SUEnableAutomaticChecks -bool false
defaults delete com.thomplth.Debut SUSkippedVersion 2>/dev/null || true
# Ruby/WEBrick ships in the Tahoe base image; the guest needs no Xcode/Python install.
/usr/bin/ruby -run -e httpd "$fixture" -b 127.0.0.1 -p 18765 >"$fixture/evidence/http.log" 2>&1 &
server_pid=$!
for _ in {1..20}; do
    if curl -fsS http://127.0.0.1:18765/appcast.xml >/dev/null 2>&1; then break; fi
    sleep 1
done
curl -fsS http://127.0.0.1:18765/appcast.xml >/dev/null
open -a "$app"
for _ in {1..30}; do
    old_pid="$(pgrep -x Debut | head -1 || true)"
    [[ -z "$old_pid" ]] || break
    sleep 1
done
[[ -n "$old_pid" ]]
# Open the real menu-bar menu and invoke the same update command a user does.
for _ in {1..30}; do
    "$fixture/update-driver" "$old_pid" 'Debut' || true
    if "$fixture/update-driver" "$old_pid" 'Check for Updates...' || "$fixture/update-driver" "$old_pid" 'Check for Updates…'; then break; fi
    sleep 1
done
"$fixture/update-driver" "$old_pid" dump > "$fixture/evidence/initial-ax.txt"
installed=false
for _ in {1..120}; do
    for pid in $(pgrep -x Debut || true) $(pgrep -x Updater || true); do
        "$fixture/update-driver" "$pid" 'Install Update' || true
        "$fixture/update-driver" "$pid" 'Install and Relaunch' || true
        "$fixture/update-driver" "$pid" 'Relaunch' || true
    done
    # Read a fresh plist process and require a distinct running process from the
    # installed path. Merely seeing the replacement on disk is not a relaunch.
    actual="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist" 2>/dev/null || true)"
    new_pid="$(pgrep -x Debut | head -1 || true)"
    if [[ "$actual" == "$expected" && -n "$new_pid" && "$new_pid" != "$old_pid" ]] && ps -p "$new_pid" -o command= | grep -Fq "$app/Contents/MacOS/Debut"; then
        installed=true
        break
    fi
    sleep 1
done
for pid in $(pgrep -x Debut || true) $(pgrep -x Updater || true); do
    "$fixture/update-driver" "$pid" dump >> "$fixture/evidence/final-ax.txt"
done
codesign --verify --deep --strict "$app"
if [[ "$installed" != true ]]; then
    echo 'FAIL: Sparkle did not install and relaunch the candidate' >&2
    cat "$fixture/evidence/final-ax.txt" >&2
    exit 1
fi
# The installed executable must be the candidate bytes, not just a stamped plist.
hdiutil attach "$fixture/Debut.dmg" -readonly -nobrowse -mountpoint "$mount" -quiet
cmp "$app/Contents/MacOS/Debut" "$mount/Debut.app/Contents/MacOS/Debut"
echo "PASS: real Sparkle update installed build $expected and relaunched ($old_pid -> $new_pid)" | tee "$fixture/evidence/result.txt"
