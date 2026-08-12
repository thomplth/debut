#!/bin/bash
set -euo pipefail

SHARE_DIR="/Volumes/My Shared Files"
APP_ARCHIVE="$SHARE_DIR/${1:?missing app archive}"
FIXTURE="$SHARE_DIR/${2:?missing fixture}"
PROFILE="${3:?missing profile}"
RESULTS="$SHARE_DIR/performance-results"
APP="/Applications/Debut.app"
SYSTEM_TCC_DB="/Library/Application Support/com.apple.TCC/TCC.db"

case "$PROFILE" in typical) processes=4 ;; busy) processes=7 ;; stress) processes=10 ;; *) exit 2 ;; esac
console_user="$(stat -f %Su /dev/console)"
console_uid="$(id -u "$console_user")"
console_home="$(dscl . -read "/Users/$console_user" NFSHomeDirectory | awk '{print $2}')"
USER_TCC_DB="$console_home/Library/Application Support/com.apple.TCC/TCC.db"
as_console() { sudo launchctl asuser "$console_uid" sudo -u "$console_user" -- "$@"; }
grant_post_event() {
    local client="$1" requirement csreq_hex escaped_client timestamp
    requirement="$(codesign -d -r- "$client" 2>&1 | awk -F ' => ' '/designated/{print $2}')"
    csreq_hex="$(printf '%s' "$requirement" | csreq -r- -b /dev/stdout | xxd -p | tr -d '\n')"
    escaped_client="${client//\'/\'\'}"
    timestamp="$(date +%s)"
    sudo sqlite3 "$SYSTEM_TCC_DB" "INSERT OR REPLACE INTO access VALUES(\
'kTCCServicePostEvent','$escaped_client',1,2,4,1,X'$csreq_hex',NULL,0,'UNUSED',NULL,0,$timestamp,NULL,NULL,'UNUSED',$timestamp);"
    sqlite3 "$USER_TCC_DB" "INSERT OR REPLACE INTO access VALUES(\
'kTCCServicePostEvent','$escaped_client',1,2,4,1,X'$csreq_hex',NULL,0,'UNUSED',NULL,0,$timestamp,NULL,NULL,'UNUSED',$timestamp);"
}
cleanup() {
    local ready_file fixture_pid
    shopt -s nullglob
    for ready_file in /tmp/debut-performance-fixture-*.ready.json; do
        fixture_pid="$(jq -r .pid "$ready_file")"
        as_console kill "$fixture_pid" 2>/dev/null || true
    done
    shopt -u nullglob
    as_console pkill -f '/Applications/Debut.app/Contents/MacOS/Debut' 2>/dev/null || true
}
trap cleanup EXIT

rm -rf "$RESULTS" "$APP"
mkdir -p "$RESULTS"
ditto -x -k "$APP_ARCHIVE" /Applications
grant_post_event "$FIXTURE"
sudo killall tccd 2>/dev/null || true
as_console rm -f /tmp/debut-performance-fixture-*.ready.json
for ((index=0; index<processes; index++)); do
    as_console env DEBUT_PERFORMANCE_PROFILE="$PROFILE" "$FIXTURE" --process-index "$index" >/tmp/debut-fixture-$index.log 2>&1 &
done

deadline=$((SECONDS + 45))
while (( SECONDS < deadline )); do
    shopt -s nullglob
    ready_files=(/tmp/debut-performance-fixture-*.ready.json)
    shopt -u nullglob
    count="${#ready_files[@]}"
    (( count >= processes )) && break
    sleep 1
done
(( count >= processes )) || { echo "Fixtures did not become ready" >&2; exit 1; }

# The performance suite intentionally keeps previews enabled. Scenarios are named in the
# artifact even when a VM cannot inject a particular interaction, so informational results
# remain distinguishable from gating budgets.
as_console open "$APP"
sleep 8
diagnostic="$console_home/Library/Application Support/Debut/diagnostic.json"
as_console "$FIXTURE" --drive "$RESULTS/input-$PROFILE.jsonl"
for scenario in launch-restore overlay-first-frame first-preview all-previews preview-1 preview-5 preview-10 preview-21 preview-50 selection-cycle stage-switch hidden-idle-45s cycles-100 process-exit title-change ax-timeout wallpaper-capture wallpaper-cancellation; do
    start="$(perl -MTime::HiRes=time -e 'printf "%.6f", time')"
    case "$scenario" in
        title-change)
            fixture_pid="$(jq -r .pid "${ready_files[1]}")"
            as_console kill -USR1 "$fixture_pid"
            ;;
        process-exit)
            fixture_pid="$(jq -r .pid "${ready_files[0]}")"
            as_console kill "$fixture_pid" 2>/dev/null || true
            ;;
        hidden-idle-45s) sleep 45 ;;
        cycles-100) for _ in {1..100}; do as_console /usr/bin/kill -INFO "$(pgrep -f '/Applications/Debut.app/Contents/MacOS/Debut' | head -1)" 2>/dev/null || true; done ;;
        ax-timeout)
            fixture_pid="$(jq -r .pid "${ready_files[2]}")"
            as_console kill -USR2 "$fixture_pid"
            sleep 1
            ;;
    esac
    end="$(perl -MTime::HiRes=time -e 'printf "%.6f", time')"
    printf '{"scenario":"%s","profile":"%s","durationMilliseconds":%.3f,"gating":%s}\n' \
        "$scenario" "$PROFILE" "$(awk "BEGIN { print ($end-$start)*1000 }")" \
        "$([[ "$scenario" == hidden-idle-45s || "$scenario" == cycles-100 ]] && echo true || echo false)" \
        >> "$RESULTS/scenarios-$PROFILE.jsonl"
done
[[ -f "$diagnostic" ]] && cp "$diagnostic" "$RESULTS/diagnostic-$PROFILE.json"
