#!/bin/bash
set -euo pipefail

# Guest half of the README media capture. Mirrors tart-e2e-guest.sh — install the host
# build, grant TCC, space windows, run a driver — but the windows here are meant to look
# like a desk someone works at, not like deterministic fixtures.

SHARE_DIR="/Volumes/My Shared Files"
APP_ARCHIVE="$SHARE_DIR/${1:?missing app archive name}"
DEMO_SOURCE="$SHARE_DIR/${2:?missing demo executable name}"
DOCS_ARCHIVE="$SHARE_DIR/${3:?missing docs archive name}"
DISPLAY_MODE="${4:-1440x900}"
PROVISION_SOURCE="$SHARE_DIR/${5:?missing desktop provisioner}"
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
    local service="$1" client="$2" client_type="$3" signed_path="$4" indirect="${5:-UNUSED}"
    local requirement csreq_hex timestamp
    requirement="$(codesign -d -r- "$signed_path" 2>&1 | awk -F ' => ' '/designated/{print $2}')"
    csreq_hex="$(printf '%s' "$requirement" | csreq -r- -b /dev/stdout | xxd -p | tr -d '\n')"
    timestamp="$(date +%s)"
    for db in "$SYSTEM_TCC_DB" "$USER_TCC_DB"; do
        sudo sqlite3 "$db" "INSERT OR REPLACE INTO access VALUES(\
'$service','${client//\'/\'\'}',$client_type,2,4,1,X'$csreq_hex',NULL,0,'$indirect',NULL,0,$timestamp,NULL,NULL,'UNUSED',$timestamp);" 2>/dev/null || true
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
grant kTCCServiceAccessibility "$PROVISION_SOURCE" 1 "$PROVISION_SOURCE"
grant kTCCServicePostEvent "$PROVISION_SOURCE" 1 "$PROVISION_SOURCE"
# SSH is the responsible process for both direct and loopback guest sessions.
# A reused E2E image may deliberately contain denied grants from permission tests.
for service in kTCCServiceAccessibility kTCCServiceScreenCapture kTCCServicePostEvent; do
    grant "$service" /usr/libexec/sshd-keygen-wrapper 1 /usr/libexec/sshd-keygen-wrapper
done
# The cover switches the disposable guest's native appearance via System Events.
for client in "$DEMO_SOURCE" /usr/libexec/sshd-keygen-wrapper /usr/bin/osascript; do
    grant kTCCServiceAppleEvents "$client" 1 "$client" com.apple.systemevents
done
sudo killall tccd 2>/dev/null || true
# Clear periodic capture reminders in the disposable guest, as the E2E fixture does.
screen_capture_approvals="$console_home/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist"
for approval_client in "com.thomplth.Debut" "$DEMO_SOURCE" "$PROVISION_SOURCE" "/usr/libexec/sshd-keygen-wrapper"; do
    as_console env HOME="$console_home" defaults write "$screen_capture_approvals" "$approval_client" -date "3024-01-01 00:00:00 +0000"
done
as_console killall cfprefsd 2>/dev/null || true
as_console killall UserNotificationCenter 2>/dev/null || true
as_console killall universalAccessAuthWarn 2>/dev/null || true
as_console killall -9 replayd 2>/dev/null || true

echo "Clearing prior state and quieting the desktop..."
as_console pkill -f "Debut.app" 2>/dev/null || true
# SIGKILL, not SIGTERM: Terminal refuses a polite quit while a shell is running in a window, so
# every earlier capture left its session behind and the next one opened another on top. It also
# denies AppKit the chance to write the saved state the next block is about to delete.
for app in TextEdit Safari Terminal Calculator Notes Preview Chess Weather Stocks KeyCastr "System Settings"; do
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
as_console rm -f "$console_home/Desktop/SPACE-LAB-SENTINEL.txt"
as_console env HOME="$console_home" defaults write com.apple.Terminal NSQuitAlwaysKeepsWindows -bool false
as_console env HOME="$console_home" defaults write -g NSQuitAlwaysKeepsWindows -bool false
as_console env HOME="$console_home" defaults write com.apple.WindowManager StandardHideWidgets -bool true
as_console env HOME="$console_home" defaults write com.apple.dock autohide -bool true
as_console killall Dock 2>/dev/null || true
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

echo "Preparing the display before Debut starts..."
as_console env HOME="$console_home" "$DEMO_SOURCE" --prepare-display --display "$DISPLAY_MODE"
# Consistent capture settings, independent of the guest's previous session.
as_console mkdir -p "$console_home/Library/Application Support/Debut"
demo_stage_scale=1.4
as_console tee "$console_home/Library/Application Support/Debut/settings.json" >/dev/null <<JSON
{"launchAtLogin":false,"excludedBundleIDs":[],"glassStyle":"Clear","stageCornerRadius":40,"inactiveStageScale":0.7,"stageScale":$demo_stage_scale,"features":{"fasterDesktopSwitching":false}}
JSON

echo "Provisioning three real desktops through Mission Control..."
as_console env HOME="$console_home" "$PROVISION_SOURCE" reset-desktops
as_console env HOME="$console_home" "$PROVISION_SOURCE" provision-desktops 3
as_console env HOME="$console_home" "$PROVISION_SOURCE" switch-to-desktop 0
as_console pkill -f "Debut.app" 2>/dev/null || true
sleep 2

echo "Opening the nine README example windows..."
rm -rf "$DESK_DIR"
mkdir -p "$DESK_DIR"
ditto -x -k "$DOCS_ARCHIVE" "$DESK_DIR"
cat > "$DESK_DIR/Project notes.rtf" <<'RTF'
{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}{\colortbl;\red45\green105\blue180;}\f0\fs64\cf1 Project notes\par\cf0\fs32\par Monday, September 21\par\par A few things to work on this week.\par\par 1. Review the latest designs\par 2. Finish the prototype\par 3. Share a short update\par\par Keep the first version simple.}
RTF
cat > "$DESK_DIR/Reading list.rtf" <<'RTF'
{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}{\colortbl;\red150\green85\blue55;}\f0\fs64\cf1 Reading list\par\cf0\fs32\par Books for a quiet afternoon\par\par The Design of Everyday Things\par A Field Guide to Getting Lost\par The Creative Act\par\par Notes\par Pick one book for the weekend.}
RTF
chown -R "$console_user" "$DESK_DIR"
as_console touch "$console_home/.hushlogin"
as_console open -a Safari "$DESK_DIR/html/index.html"
sleep 3
as_console open -a Safari "$DESK_DIR/html/04-spaces.html"
sleep 3
as_console open -a Chess
as_console open -a Weather
as_console open -a Stocks
sleep 5
as_console open -a TextEdit "$DESK_DIR/Project notes.rtf"
sleep 2
as_console open -a TextEdit "$DESK_DIR/Reading list.rtf"
sleep 2
cat > "$DESK_DIR/Research.command" <<'SH'
#!/bin/zsh
clear
printf '\033]0;Research\007'
printf 'Research\n\n  Notes collected        12\n  References reviewed     8\n  Ideas to explore        3\n\n'
export PS1='$ '
exec /bin/zsh -f
SH
cat > "$DESK_DIR/Project.command" <<'SH'
#!/bin/zsh
clear
printf '\033]0;Project\007'
printf 'Project\n\n  All changes saved.\n  Ready for the next session.\n\n'
export PS1='$ '
exec /bin/zsh -f
SH
chmod +x "$DESK_DIR/Research.command" "$DESK_DIR/Project.command"
chown -R "$console_user" "$DESK_DIR"
as_console open "$DESK_DIR/Research.command"
sleep 3
as_console open "$DESK_DIR/Project.command"
sleep 3

# KeyCastr is installed only in the disposable capture guest.
keycastr_archive="$SHARE_DIR/KeyCastr-0.11.1.app.zip"
[[ -f "$keycastr_archive" ]] || { echo "Missing KeyCastr archive" >&2; exit 1; }
sudo ditto -x -k "$keycastr_archive" /Applications
grant kTCCServiceListenEvent io.github.keycastr 0 /Applications/KeyCastr.app
grant kTCCServiceAccessibility io.github.keycastr 0 /Applications/KeyCastr.app
as_console env HOME="$console_home" defaults write io.github.keycastr alwaysShowPrefs -bool false
as_console env HOME="$console_home" defaults write io.github.keycastr selectedVisualizer -string Default
as_console env HOME="$console_home" defaults write io.github.keycastr default.fontSize -float 64
as_console env HOME="$console_home" defaults write io.github.keycastr default.commandKeysOnly -bool false
as_console env HOME="$console_home" defaults write io.github.keycastr default.allModifiedKeys -bool false
as_console env HOME="$console_home" defaults write io.github.keycastr default.fadeDelay -float 1.2
as_console env HOME="$console_home" defaults write io.github.keycastr default.fadeDuration -float 0.15
as_console env HOME="$console_home" defaults write io.github.keycastr default.keystrokeDelay -float 0.15
as_console env HOME="$console_home" defaults write io.github.keycastr 'NSWindow Frame KCBezelWindow default.bezelWindow' -string '70 38 1300 80 0 0 1440 900 '
as_console env HOME="$console_home" defaults write io.github.keycastr SUEnableAutomaticChecks -bool false
sudo killall tccd 2>/dev/null || true

as_console open "$APP_PATH"
sleep 5

echo "Capturing..."
rm -rf "$MEDIA_DIR"
mkdir -p "$MEDIA_DIR"
chown "$console_user" "$MEDIA_DIR" 2>/dev/null || true
set +e
as_console env HOME="$console_home" "$DEMO_SOURCE" \
    --output "$MEDIA_DIR" "${@:6}"
status=$?
set -e

echo "Media written to $MEDIA_DIR"
exit "$status"
