#!/bin/bash
set -euo pipefail

# Guest half of the README media capture. Mirrors tart-e2e-guest.sh — install the host
# build, grant TCC, stage windows, run a driver — but the windows here are meant to look
# like a desk someone works at, not like deterministic fixtures.

SHARE_DIR="/Volumes/My Shared Files"
APP_ARCHIVE="$SHARE_DIR/${1:?missing app archive name}"
DEMO_SOURCE="$SHARE_DIR/${2:?missing demo executable name}"
DOCS_ARCHIVE="$SHARE_DIR/${3:?missing docs archive name}"
DISPLAY_MODE="${4:-1440x900}"
MEDIA_DIR="$SHARE_DIR/media"
APP_PATH="/Applications/Debut.app"
SYSTEM_TCC_DB="/Library/Application Support/com.apple.TCC/TCC.db"
DESK_DIR="/tmp/debut-demo-desk"

if [[ ! -f "$APP_ARCHIVE" || ! -x "$DEMO_SOURCE" ]]; then
    echo "The staged demo artifacts are missing; run scripts/demo-capture.sh from the host." >&2
    exit 1
fi

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

grant() {
    local service="$1" client="$2" client_type="$3" signed_path="$4"
    local requirement csreq_hex timestamp
    requirement="$(codesign -d -r- "$signed_path" 2>&1 | awk -F ' => ' '/designated/{print $2}')"
    csreq_hex="$(printf '%s' "$requirement" | csreq -r- -b /dev/stdout | xxd -p | tr -d '\n')"
    timestamp="$(date +%s)"
    for db in "$SYSTEM_TCC_DB" "$USER_TCC_DB"; do
        sudo sqlite3 "$db" "INSERT OR REPLACE INTO access VALUES(\
'$service','${client//\'/\'\'}',$client_type,2,4,1,X'$csreq_hex',NULL,0,'UNUSED',NULL,0,$timestamp,NULL,NULL,'UNUSED',$timestamp);" 2>/dev/null || true
    done
}

echo "Installing the host build in the guest..."
sudo rm -rf "$APP_PATH"
sudo ditto -x -k "$APP_ARCHIVE" /Applications

echo "Granting Accessibility, Screen Recording, and event posting..."
grant kTCCServiceAccessibility "com.thomplth.Debut" 0 "$APP_PATH"
grant kTCCServiceScreenCapture "com.thomplth.Debut" 0 "$APP_PATH"
grant kTCCServiceAccessibility "$DEMO_SOURCE" 1 "$DEMO_SOURCE"
grant kTCCServiceScreenCapture "$DEMO_SOURCE" 1 "$DEMO_SOURCE"
grant kTCCServicePostEvent "$DEMO_SOURCE" 1 "$DEMO_SOURCE"
sudo killall tccd 2>/dev/null || true

echo "Clearing prior state and quieting the desktop..."
as_console pkill -f "Debut.app" 2>/dev/null || true
# SIGKILL, not SIGTERM: Terminal refuses a polite quit while a shell is running in a window, so
# every earlier capture left its session behind and the next one opened another on top. It also
# denies AppKit the chance to write the saved state the next block is about to delete.
for app in TextEdit Safari Terminal Calculator Notes Preview; do
    as_console pkill -9 -x "$app" 2>/dev/null || true
done
# Resume reopens every window the last run left behind, and those stack up: one capture reached
# eleven Terminal windows, ten of them restored corpses, and they survived a guest reboot. Tahoe
# keeps that state under Daemon Containers, not the `~/Library/Saved Application State` every
# recipe names — that path does not even exist here, which is why deleting it changed nothing.
sleep 4
echo "  survivors after the kill: $(pgrep -lx Terminal | wc -l | tr -d ' ') Terminal, $(pgrep -lx TextEdit | wc -l | tr -d ' ') TextEdit, $(pgrep -lx Safari | wc -l | tr -d ' ') Safari"
as_console rm -rf "$console_home/Library/Saved Application State"
sudo find "$console_home/Library/Daemon Containers" -type d -name "*.savedState" -maxdepth 5 -exec rm -rf {} + 2>/dev/null || true
rm -rf /tmp/debut-e2e-fixtures
as_console env HOME="$console_home" defaults write com.apple.Terminal NSQuitAlwaysKeepsWindows -bool false
as_console env HOME="$console_home" defaults write -g NSQuitAlwaysKeepsWindows -bool false
# Debut manages windows, so the desk needs windows: left alone Safari folds every `open` into
# another tab of the one it already has.
as_console env HOME="$console_home" defaults write com.apple.Safari TabCreationPolicy -int 0
as_console env HOME="$console_home" defaults write com.apple.Safari AlwaysRestoreSessionAtLaunch -bool false
as_console env HOME="$console_home" defaults write com.apple.TextEdit NSFixedPitchFontSize -int 16
as_console rm -rf "$console_home/Library/Application Support/Debut"
as_console env HOME="$console_home" defaults write com.thomplth.Debut hasCompletedOnboarding -bool true
# Focus stays on for the whole capture so no banner lands mid-clip.
as_console mkdir -p "$console_home/Library/DoNotDisturb/DB"
as_console tee "$console_home/Library/DoNotDisturb/DB/Assertions.json" >/dev/null <<'JSON'
{"storeAssertionRecords":[{"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.donotdisturb.mode.default"},"assertionStartDateTimestamp":0}]}
JSON
as_console killall NotificationCenter 2>/dev/null || true

echo "Opening a desk worth photographing..."
rm -rf "$DESK_DIR"
mkdir -p "$DESK_DIR"
ditto -x -k "$DOCS_ARCHIVE" "$DESK_DIR"
cat > "$DESK_DIR/Release notes.txt" <<'TXT'
Release notes — draft
=====================

Shipped
  * The overlay opens on the display holding the focused window, not
    on whichever display macOS calls main.
  * The plates reach inside a full-screen app's Space.
  * Stage labels follow position, so reordering needs no rename.
  * Quitting an app no longer forgets where its windows lived; the
    assignments go dormant and come back on the next launch.

Still to write up
  * The reconciliation rules for dormant windows.
  * Why window titles are not stable keys, with the Terminal example.
  * The exclusion list, and the five layers that have to honour it.
TXT
cat > "$DESK_DIR/Notes.txt" <<'TXT'
Stages
======

  1  Writing   — the draft and the docs
  2  Review    — the diff and the terminal
  3  Reading   — everything that can wait

Command-Tab cycles inside a stage. It never leaves one.
Command-Option-Tab moves between the stages themselves.
Control-1 through Control-9 jump straight to a stage.

Down-arrow inside the overlay sends the selected window to the
stage below, which is how the three above got their windows.
TXT
cat > "$DESK_DIR/Reading list.txt" <<'TXT'
Reading list
============

  [ ]  The Accessibility API's window notifications, in full
  [ ]  ScreenCaptureKit: filters, and what excludingDesktopWindows
       actually excludes
  [ ]  Why CGWindowID is not a durable identifier
  [x]  Spaces, and the parts of them that are private API

Nothing here is urgent, which is the whole reason it lives on
its own stage.
TXT
chown -R "$console_user" "$DESK_DIR"

# A stock guest shell greets every window with a wall of "Last login" lines.
as_console touch "$console_home/.hushlogin"
# Ends by exec'ing a login shell: a plain `.command` exits when it finishes, and the terminal
# then reads "[Process completed]" over a dead session in every frame.
cat > "$DESK_DIR/session.command" <<'SH'
#!/bin/zsh
clear
print '$ plutil -extract state json -o - ~/Library/Application\ Support/Debut/diagnostic.json'
plutil -extract state json -o - "$HOME/Library/Application Support/Debut/diagnostic.json"
print
exec /bin/zsh -l
SH
cat > "$DESK_DIR/events.command" <<'SH'
#!/bin/zsh
clear
print '$ plutil -extract events json -o - ~/Library/Application\ Support/Debut/diagnostic.json | tail'
plutil -extract events json -o - "$HOME/Library/Application Support/Debut/diagnostic.json" \
    | tr ',' '\n' | tail -14
print
exec /bin/zsh -l
SH
chmod +x "$DESK_DIR/session.command" "$DESK_DIR/events.command"
chown -R "$console_user" "$DESK_DIR"

# Nine windows: arrangeStages moves six out of the startup stage, and three plates of three is
# what the README is trying to show.
as_console open -a Safari "$DESK_DIR/html/index.html"
sleep 5
as_console open -a Safari "$DESK_DIR/html/02-architecture.html"
sleep 4
as_console open -a Safari "$DESK_DIR/html/04-stages.html"
sleep 4
as_console open -a Calculator
sleep 3
as_console open -a TextEdit "$DESK_DIR/Reading list.txt"
sleep 3
as_console open -a TextEdit "$DESK_DIR/Release notes.txt"
sleep 3
as_console open -a TextEdit "$DESK_DIR/Notes.txt"
sleep 3

echo "  desk processes: $(pgrep -lx Terminal | wc -l | tr -d ' ') Terminal, $(pgrep -lx TextEdit | wc -l | tr -d ' ') TextEdit, $(pgrep -lx Safari | wc -l | tr -d ' ') Safari"

echo "Launching Debut..."
as_console open "$APP_PATH"
for _ in {1..45}; do
    if [[ -f "$console_home/Library/Application Support/Debut/diagnostic.json" ]] \
        && /usr/bin/plutil -extract state.eventTapRunning raw -o - \
            "$console_home/Library/Application Support/Debut/diagnostic.json" 2>/dev/null | grep -q true; then
        break
    fi
    sleep 1
done

# Opened last so the terminals have a running Debut to report on, and so they land at the top
# of the MRU order where the overlay puts them first.
as_console open "$DESK_DIR/events.command"
sleep 4
as_console open "$DESK_DIR/session.command"
sleep 5

echo "Capturing..."
rm -rf "$MEDIA_DIR"
mkdir -p "$MEDIA_DIR"
chown "$console_user" "$MEDIA_DIR" 2>/dev/null || true
set +e
as_console env HOME="$console_home" "$DEMO_SOURCE" \
    --output "$MEDIA_DIR" --display "$DISPLAY_MODE" "${@:5}"
status=$?
set -e

echo "Media written to $MEDIA_DIR"
exit "$status"
