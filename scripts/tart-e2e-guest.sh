#!/bin/bash
set -euo pipefail

SHARE_DIR="/Volumes/My Shared Files"
APP_ARCHIVE="$SHARE_DIR/${1:?missing app archive name}"
E2E_SOURCE="$SHARE_DIR/${2:?missing E2E executable name}"
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
sleep 2

echo "Launching Debut in the guest Aqua session..."
as_console open "$APP_PATH"
sleep 4

echo "Running all checks, including the four synthetic-drag checks skipped on GitHub-hosted runners..."
rm -rf "$RESULTS_DIR"
mkdir -p "$RESULTS_DIR"
unset GITHUB_ACTIONS
set +e
as_console env HOME="$console_home" GITHUB_ACTIONS= "$E2E_SOURCE"
status=$?
set -e

if [[ -d /tmp/debut-e2e-screenshots ]]; then
    ditto /tmp/debut-e2e-screenshots "$RESULTS_DIR/screenshots"
fi
if [[ -f "$console_home/Library/Application Support/Debut/diagnostic.json" ]]; then
    cp "$console_home/Library/Application Support/Debut/diagnostic.json" "$RESULTS_DIR/diagnostic.json"
fi

exit "$status"
