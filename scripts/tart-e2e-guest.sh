#!/bin/bash
set -euo pipefail

SHARE_DIR="/Volumes/My Shared Files"
APP_ARCHIVE="$SHARE_DIR/${1:?missing app archive name}"
E2E_SOURCE="$SHARE_DIR/${2:?missing E2E executable name}"
E2E_MODE="${3:?missing E2E mode}"
RESULTS_DIR="$SHARE_DIR/results"
APP_PATH="/Applications/Debut.app"
SYSTEM_TCC_DB="/Library/Application Support/com.apple.TCC/TCC.db"
FIXTURE_DIR="/tmp/debut-e2e-fixtures"

console_user="$(stat -f %Su /dev/console)"
if [[ -z "$console_user" || "$console_user" == "root" || "$console_user" == "loginwindow" ]]; then
    echo "A logged-in Aqua user is required; console owner is '$console_user'." >&2
    exit 1
fi
console_uid="$(id -u "$console_user")"
console_home="$(dscl . -read "/Users/$console_user" NFSHomeDirectory | awk '{print $2}')"
USER_TCC_DB="$console_home/Library/Application Support/com.apple.TCC/TCC.db"

as_console() {
    sudo launchctl asuser "$console_uid" sudo -u "$console_user" -- "$@"
}

cleanup() {
    as_console pkill -f "Debut.app" 2>/dev/null || true
    as_console pkill -x TextEdit 2>/dev/null || true
    as_console launchctl unsetenv DEBUT_DISABLE_WINDOW_PREVIEWS 2>/dev/null || true
}
trap cleanup EXIT

grant_accessibility() {
    local client="$1"
    local client_type="$2"
    local signed_path="$3"
    local requirement csreq_hex escaped_client timestamp

    requirement="$(codesign -d -r- "$signed_path" 2>&1 | awk -F ' => ' '/designated/{print $2}')"
    csreq_hex="$(printf '%s' "$requirement" | csreq -r- -b /dev/stdout | xxd -p | tr -d '\n')"
    escaped_client="${client//\'/\'\'}"
    timestamp="$(date +%s)"

    sudo sqlite3 "$SYSTEM_TCC_DB" "INSERT OR REPLACE INTO access VALUES(\
'kTCCServiceAccessibility','$escaped_client',$client_type,2,4,1,X'$csreq_hex',NULL,0,'UNUSED',NULL,0,$timestamp,NULL,NULL,'UNUSED',$timestamp);"
}

grant_post_event() {
    local client="$1"
    local signed_path="${2:-}"
    local requirement csreq_hex csreq_sql escaped_client timestamp

    if [[ -n "$signed_path" ]]; then
        requirement="$(codesign -d -r- "$signed_path" 2>&1 | awk -F ' => ' '/designated/{print $2}')"
        csreq_hex="$(printf '%s' "$requirement" | csreq -r- -b /dev/stdout | xxd -p | tr -d '\n')"
        csreq_sql="X'$csreq_hex'"
    else
        csreq_sql="NULL"
    fi
    escaped_client="${client//\'/\'\'}"
    timestamp="$(date +%s)"

    sudo sqlite3 "$SYSTEM_TCC_DB" "INSERT OR REPLACE INTO access VALUES(\
'kTCCServicePostEvent','$escaped_client',1,2,4,1,$csreq_sql,NULL,0,'UNUSED',NULL,0,$timestamp,NULL,NULL,'UNUSED',$timestamp);"
    sqlite3 "$USER_TCC_DB" "INSERT OR REPLACE INTO access VALUES(\
'kTCCServicePostEvent','$escaped_client',1,2,4,1,$csreq_sql,NULL,0,'UNUSED',NULL,0,$timestamp,NULL,NULL,'UNUSED',$timestamp);"
}

wait_for_debut_ready() {
    local diagnostic_path="$console_home/Library/Application Support/Debut/diagnostic.json"
    local deadline=$((SECONDS + 45))
    local events_json event_tap_running window_count

    while (( SECONDS < deadline )); do
        if [[ -f "$diagnostic_path" ]]; then
            events_json="$(/usr/bin/plutil -extract events json -o - "$diagnostic_path" 2>/dev/null || true)"
            event_tap_running="$(/usr/bin/plutil -extract state.eventTapRunning raw -o - "$diagnostic_path" 2>/dev/null || true)"
            window_count="$(/usr/bin/plutil -extract state.windowsInActiveStage raw -o - "$diagnostic_path" 2>/dev/null || true)"

            if grep -Eq '"event"[[:space:]]*:[[:space:]]*"app_ready"' <<< "$events_json" \
                && [[ "$event_tap_running" == "true" ]] \
                && [[ "$window_count" =~ ^[0-9]+$ ]] \
                && (( window_count >= 2 )); then
                echo "Debut is ready: event tap running with $window_count fixture windows discovered."
                return 0
            fi
        fi
        sleep 1
    done

    echo "Debut did not become ready within 45 seconds." >&2
    [[ -f "$diagnostic_path" ]] && /bin/cat "$diagnostic_path" >&2
    return 1
}

wait_for_fixture_apps() {
    local deadline=$((SECONDS + 45))
    local fixture_count fixture_pids

    while (( SECONDS < deadline )); do
        fixture_pids="$(as_console pgrep -x TextEdit 2>/dev/null || true)"
        fixture_count="$(grep -c . <<< "$fixture_pids" || true)"
        if (( fixture_count >= 2 )); then
            echo "Both TextEdit fixture processes are running."
            sleep 2
            return 0
        fi
        sleep 1
    done

    echo "Both TextEdit fixture processes did not launch within 45 seconds." >&2
    return 1
}

echo "Installing the host build in the isolated guest..."
sudo rm -rf "$APP_PATH"
sudo ditto -x -k "$APP_ARCHIVE" /Applications

echo "Granting Accessibility to Debut and the E2E input driver..."
grant_accessibility "com.thomplth.Debut" 0 "$APP_PATH"
grant_accessibility "$E2E_SOURCE" 1 "$E2E_SOURCE"
grant_post_event "$E2E_SOURCE" "$E2E_SOURCE"
sudo killall tccd 2>/dev/null || true

echo "Preparing deterministic fixture windows..."
as_console rm -rf "$console_home/Library/Application Support/Debut"
as_console env HOME="$console_home" defaults write com.thomplth.Debut hasCompletedOnboarding -bool true
rm -rf "$FIXTURE_DIR"
mkdir -p "$FIXTURE_DIR"
printf 'Debut E2E fixture one\n' > "$FIXTURE_DIR/one.txt"
printf 'Debut E2E fixture two\n' > "$FIXTURE_DIR/two.txt"
chown -R "$console_user" "$FIXTURE_DIR"

as_console launchctl setenv DEBUT_DISABLE_WINDOW_PREVIEWS 1
as_console open -na TextEdit "$FIXTURE_DIR/one.txt"
as_console open -na TextEdit "$FIXTURE_DIR/two.txt"
wait_for_fixture_apps

echo "Launching Debut in the guest Aqua session..."
as_console open "$APP_PATH"
wait_for_debut_ready

case "$E2E_MODE" in
    virtualized)
        echo "Running the stable virtualized suite; four unsupported synthetic drags are explicit skips..."
        drag_environment=(DEBUT_SKIP_VIRTUALIZED_DRAGS=1)
        ;;
    all)
        echo "Attempting all checks, including the four diagnostic synthetic drags..."
        drag_environment=()
        ;;
    *)
        echo "Unknown E2E mode: $E2E_MODE" >&2
        exit 2
        ;;
esac
rm -rf "$RESULTS_DIR"
mkdir -p "$RESULTS_DIR"
unset GITHUB_ACTIONS
set +e
as_console env HOME="$console_home" GITHUB_ACTIONS= "${drag_environment[@]}" "$E2E_SOURCE"
status=$?
set -e

if [[ -d /tmp/debut-e2e-screenshots ]]; then
    ditto /tmp/debut-e2e-screenshots "$RESULTS_DIR/screenshots"
fi
if [[ -f "$console_home/Library/Application Support/Debut/diagnostic.json" ]]; then
    cp "$console_home/Library/Application Support/Debut/diagnostic.json" "$RESULTS_DIR/diagnostic.json"
fi

exit "$status"
