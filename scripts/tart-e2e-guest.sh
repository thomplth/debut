#!/bin/bash
set -euo pipefail

SHARE_DIR="/Volumes/My Shared Files"
APP_ARCHIVE="$SHARE_DIR/${1:?missing app archive name}"
E2E_SOURCE="$SHARE_DIR/${2:?missing E2E executable name}"
E2E_MODE="${3:?missing E2E mode}"
RESULTS_DIR="$SHARE_DIR/results"
SYSTEM_TCC_DB="/Library/Application Support/com.apple.TCC/TCC.db"
FIXTURE_DIR="/tmp/debut-e2e-fixtures"

case "$E2E_MODE" in
    virtualized) DRAG_SKIP="1" ;;
    all) DRAG_SKIP="0" ;;
    *)
        echo "Unknown E2E mode: $E2E_MODE" >&2
        exit 2
        ;;
esac

# This script replaces the installed app and rewrites TCC, so refuse to run
# anywhere the host has not staged artifacts through VirtioFS.
if [[ ! -f "$APP_ARCHIVE" || ! -x "$E2E_SOURCE" ]]; then
    echo "The staged E2E artifacts are missing; run scripts/tart-e2e.sh from the host." >&2
    exit 1
fi

# The archive carries its own name, so a rename on the host cannot leave the guest installing,
# permitting and launching three different apps.
app_name="$(/usr/bin/unzip -Z1 "$APP_ARCHIVE" \
    | awk -F/ '$1 ~ /\.app$/ && !seen[$1]++ { print $1 }')"
if [[ -z "$app_name" ]]; then
    echo "The staged archive does not contain an app bundle." >&2
    exit 1
fi
APP_PATH="/Applications/$app_name"

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
    as_console pkill -f "$APP_PATH" 2>/dev/null || true
    as_console pkill -x TextEdit 2>/dev/null || true
    as_console launchctl unsetenv DEBUT_DISABLE_WINDOW_PREVIEWS 2>/dev/null || true
    as_console launchctl unsetenv DEBUT_FORCE_DISPLAY_STACK_INDICATOR 2>/dev/null || true
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

grant_screen_capture() {
    local client="$1"
    local client_type="$2"
    local signed_path="$3"
    local requirement csreq_hex escaped_client timestamp

    requirement="$(codesign -d -r- "$signed_path" 2>&1 | awk -F ' => ' '/designated/{print $2}')"
    csreq_hex="$(printf '%s' "$requirement" | csreq -r- -b /dev/stdout | xxd -p | tr -d '\n')"
    escaped_client="${client//\'/\'\'}"
    timestamp="$(date +%s)"

    sudo sqlite3 "$SYSTEM_TCC_DB" "INSERT OR REPLACE INTO access VALUES(\
'kTCCServiceScreenCapture','$escaped_client',$client_type,2,4,1,X'$csreq_hex',NULL,0,'UNUSED',NULL,0,$timestamp,NULL,NULL,'UNUSED',$timestamp);"
    sqlite3 "$USER_TCC_DB" "INSERT OR REPLACE INTO access VALUES(\
'kTCCServiceScreenCapture','$escaped_client',$client_type,2,4,1,X'$csreq_hex',NULL,0,'UNUSED',NULL,0,$timestamp,NULL,NULL,'UNUSED',$timestamp);"
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
            window_count="$(/usr/bin/plutil -extract state.windowsInActiveSpace raw -o - "$diagnostic_path" 2>/dev/null || true)"

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

bundle_id="$(/usr/bin/defaults read "$APP_PATH/Contents/Info" CFBundleIdentifier)"
# Debut keeps its state under the last component of its bundle ID; Tests/CI/AppIdentityTests.sh
# holds the two together so this stays a derivation rather than a guess.
support_dir="$console_home/Library/Application Support/${bundle_id##*.}"

echo "Granting Screen Recording and Accessibility to Debut and the E2E input driver..."
grant_accessibility "$bundle_id" 0 "$APP_PATH"
grant_screen_capture "$bundle_id" 0 "$APP_PATH"
grant_accessibility "$E2E_SOURCE" 1 "$E2E_SOURCE"
grant_post_event "$E2E_SOURCE" "$E2E_SOURCE"
# The suite samples animation frames itself rather than spawning `screencapture`, so it is a
# screen capture client in its own right; without this it would meet a TCC prompt mid-run.
grant_screen_capture "$E2E_SOURCE" 1 "$E2E_SOURCE"
sudo killall tccd 2>/dev/null || true

# A warm VM is reused across runs, and macOS's periodic screen-recording reminder is modal to
# nothing: the alerts simply stay on the desktop. They had stacked seven deep, covering the region
# every pixel-sampling check reads. Suppressing the reminder stops new ones, and quitting the
# presenter clears whatever an earlier run left behind.
# macOS keys this store by whatever it holds responsible for the capture: a bundle ID for Debut, and
# for the suite the ssh session that launched it rather than the binary itself.
screen_capture_approvals="$console_home/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist"
for approval_client in "$bundle_id" "$E2E_SOURCE" "/usr/libexec/sshd-keygen-wrapper"; do
    as_console env HOME="$console_home" defaults write \
        "$screen_capture_approvals" "$approval_client" -date "3024-01-01 00:00:00 +0000"
done
as_console killall cfprefsd 2>/dev/null || true
as_console killall UserNotificationCenter 2>/dev/null || true
as_console killall replayd 2>/dev/null || true

# Under Reduce Motion the removal transition is a 0.12s fade rather than a 0.36s spring, which is
# correct behaviour but too brief to sample as motion. The fade branch is covered by unit tests, so
# the disposable guest is pinned to the spring instead of the E2E check guessing which one it drew.
as_console env HOME="$console_home" defaults write com.apple.universalaccess reduceMotion -bool false
as_console env HOME="$console_home" defaults write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool true

echo "Preparing deterministic fixture windows..."
as_console rm -rf "$support_dir"
as_console env HOME="$console_home" defaults write "$bundle_id" hasCompletedOnboarding -bool true
rm -rf "$FIXTURE_DIR"
mkdir -p "$FIXTURE_DIR"
printf 'Debut E2E fixture one\n' > "$FIXTURE_DIR/one.txt"
printf 'Debut E2E fixture two\n' > "$FIXTURE_DIR/two.txt"
chown -R "$console_user" "$FIXTURE_DIR"

# A reused warm guest keeps whatever desktop the previous run left active. Fixture windows below
# open on the active desktop, so a run that starts anywhere but the first desktop plants fixtures
# with no empty desktop after them — breaking the drop/move checks' shared precondition.
echo "Resetting to the first desktop before planting fixtures..."
as_console env HOME="$console_home" "$E2E_SOURCE" switch-to-desktop 0

as_console open -na TextEdit "$FIXTURE_DIR/one.txt"
as_console open -na TextEdit "$FIXTURE_DIR/two.txt"
wait_for_fixture_apps

# A freshly cloned VM logs in with one desktop, and a space is a desktop, so without this the
# suite cannot switch a space or move a window between two. Debut builds its space list at
# launch, so the desktops have to exist first.
echo "Provisioning desktops so spaces have somewhere to be..."
as_console env HOME="$console_home" "$E2E_SOURCE" provision-desktops 3

echo "Launching Debut in the guest Aqua session..."
as_console launchctl setenv DEBUT_FORCE_DISPLAY_STACK_INDICATOR 1
as_console env DEBUT_FORCE_DISPLAY_STACK_INDICATOR=1 "$APP_PATH/Contents/MacOS/Debut" --force-display-stack-indicator >/tmp/debut-e2e-debut.log 2>&1 </dev/null &
wait_for_debut_ready

if [[ "$DRAG_SKIP" == "1" ]]; then
    echo "Running the stable virtualized suite; four unsupported synthetic drags are explicit skips..."
else
    echo "Attempting all checks, including the four diagnostic synthetic drags..."
fi
rm -rf "$RESULTS_DIR"
mkdir -p "$RESULTS_DIR"
unset GITHUB_ACTIONS
set +e
as_console env HOME="$console_home" GITHUB_ACTIONS= \
    DEBUT_SKIP_VIRTUALIZED_DRAGS="$DRAG_SKIP" "$E2E_SOURCE"
status=$?
set -e

if [[ -d /tmp/debut-e2e-screenshots ]]; then
    ditto /tmp/debut-e2e-screenshots "$RESULTS_DIR/screenshots"
fi
if [[ -f "$console_home/Library/Application Support/Debut/diagnostic.json" ]]; then
    cp "$console_home/Library/Application Support/Debut/diagnostic.json" "$RESULTS_DIR/diagnostic.json"
fi

exit "$status"
