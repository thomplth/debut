#!/bin/bash
set -euo pipefail

SHARE_DIR="/Volumes/My Shared Files/glass-lab"
ARTIFACT_DIR="$SHARE_DIR/artifacts"
RESULTS_DIR="$SHARE_DIR/results"
WORK_DIR="/tmp/debut-glass-lab"

console_user="$(stat -f %Su /dev/console)"
console_uid="$(id -u "$console_user")"

as_console() {
    sudo launchctl asuser "$console_uid" sudo -u "$console_user" -- "$@"
}

set_accessibility() {
    local state="$1" reduce=false contrast=false
    case "$state" in
        normal) ;;
        reduce-transparency) reduce=true ;;
        increase-contrast) contrast=true ;;
        reduce-and-contrast) reduce=true; contrast=true ;;
        *) echo "Unknown accessibility state: $state" >&2; exit 2 ;;
    esac
    as_console defaults write com.apple.universalaccess reduceTransparency -bool "$reduce"
    as_console defaults write com.apple.universalaccess increaseContrast -bool "$contrast"
    as_console killall cfprefsd 2>/dev/null || true
    sleep 1
}

case "${1:-}" in
    prepare)
        [[ -d "$ARTIFACT_DIR" ]] || { echo "Missing glass lab artifacts." >&2; exit 1; }
        rm -rf "$WORK_DIR"
        mkdir -p "$WORK_DIR/apps"
        mkdir -p "$RESULTS_DIR"
        for archive in "$ARTIFACT_DIR"/*.app.zip; do
            ditto -x -k "$archive" "$WORK_DIR/apps"
        done
        as_console open -a TextEdit
        as_console open -a Calculator
        as_console open -a Safari
        sleep 3
        ;;
    accessibility)
        set_accessibility "${2:?missing accessibility state}"
        ;;
    appearance)
        case "${2:?missing appearance}" in
            light) dark_mode=false ;;
            dark) dark_mode=true ;;
            *) echo "Unknown appearance: $2" >&2; exit 2 ;;
        esac
        as_console osascript -e \
            "tell application \"System Events\" to tell appearance preferences to set dark mode to $dark_mode"
        sleep 2
        ;;
    native)
        duration="${2:-3}"
        as_console osascript \
            -e 'tell application "System Events"' \
            -e 'key down command' \
            -e 'key code 48' \
            -e "delay $duration" \
            -e 'key up command' \
            -e 'end tell'
        ;;
    launch)
        artifact="${2:?missing artifact}"
        appearance="${3:?missing appearance}"
        app="$WORK_DIR/apps/$artifact.app"
        [[ -d "$app" ]] || { echo "Missing app: $app" >&2; exit 1; }
        as_console open -na "$app" --args --appearance "$appearance"
        ;;
    stop)
        as_console pkill -x DebutGlassLab 2>/dev/null || true
        ;;
    cleanup)
        as_console pkill -x DebutGlassLab 2>/dev/null || true
        as_console defaults write com.apple.universalaccess reduceTransparency -bool false
        as_console defaults write com.apple.universalaccess increaseContrast -bool false
        as_console osascript -e \
            'tell application "System Events" to tell appearance preferences to set dark mode to false'
        as_console killall cfprefsd 2>/dev/null || true
        ;;
    *)
        echo "Usage: $0 <prepare|appearance MODE|accessibility STATE|native SECONDS|launch ARTIFACT APPEARANCE|stop|cleanup>" >&2
        exit 2
        ;;
esac
