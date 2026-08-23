#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
    echo "ci-e2e.sh only runs on GitHub Actions so it cannot disturb a developer session." >&2
    exit 1
fi

xcode_path="/Applications/Xcode_26.3.app/Contents/Developer"
if [[ ! -d "$xcode_path" ]]; then
    echo "Required hosted toolchain is missing: $xcode_path" >&2
    exit 1
fi
export DEVELOPER_DIR="$xcode_path"
export TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault

system_tcc_db="/Library/Application Support/com.apple.TCC/TCC.db"
fixture_dir="${RUNNER_TEMP}/debut-e2e-fixtures"
screen_capture_approvals="$HOME/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist"

cleanup() {
    pkill -f "${app_path:-/Applications/nothing.app}" 2>/dev/null || true
    pkill -x TextEdit 2>/dev/null || true
    launchctl unsetenv DEBUT_DISABLE_WINDOW_PREVIEWS 2>/dev/null || true
}
trap cleanup EXIT

echo "Suppressing the disposable runner's screen capture reminder..."
mkdir -p "$(dirname "$screen_capture_approvals")"
defaults write "$screen_capture_approvals" "/bin/bash" -date "3024-01-01 00:00:00 +0000"
defaults write "$screen_capture_approvals" "/opt/hca/hosted-compute-agent" -date "3024-01-01 00:00:00 +0000"
killall cfprefsd 2>/dev/null || true
killall replayd 2>/dev/null || true
sleep 1
/usr/sbin/screencapture -x "$RUNNER_TEMP/screen-capture-preflight.png" || true
plutil -p "$screen_capture_approvals"
rm -f "$RUNNER_TEMP/screen-capture-preflight.png"

echo "Building and installing Debut..."
build_log="$(mktemp)"
./scripts/build-app.sh | tee "$build_log"
app_bundle="$(awk '/^Built: /{ sub(/^Built: /, ""); print }' "$build_log")"
rm -f "$build_log"
if [[ -z "$app_bundle" || ! -d "$app_bundle" ]]; then
    echo "build-app.sh did not report a built app bundle." >&2
    exit 1
fi
app_path="/Applications/$(basename "$app_bundle")"
sudo rm -rf "$app_path"
sudo cp -R "$app_bundle" "$app_path"
bundle_id="$(/usr/bin/defaults read "$app_path/Contents/Info" CFBundleIdentifier)"

echo "Granting Accessibility access inside the disposable runner..."
requirement=$(codesign -d -r- "$app_path" 2>&1 | awk -F ' => ' '/designated/{print $2}')
csreq_hex=$(printf '%s' "$requirement" | csreq -r- -b /dev/stdout | xxd -p | tr -d '\n')
timestamp=$(date +%s)
sudo sqlite3 "$system_tcc_db" "INSERT OR REPLACE INTO access VALUES(\
'kTCCServiceAccessibility','$bundle_id',0,2,4,1,X'$csreq_hex',NULL,0,'UNUSED',NULL,0,$timestamp,NULL,NULL,'UNUSED',$timestamp);"
sudo killall tccd 2>/dev/null || true

# launchctl reaches the app, which `open` spawns through launchd; the export reaches the suite,
# which this shell spawns directly. Both need to agree that previews are off.
launchctl setenv DEBUT_DISABLE_WINDOW_PREVIEWS 1
export DEBUT_DISABLE_WINDOW_PREVIEWS=1

echo "Preparing deterministic fixture windows..."
rm -rf "$HOME/Library/Application Support/${bundle_id##*.}"
defaults write "$bundle_id" hasCompletedOnboarding -bool true
mkdir -p "$fixture_dir"
printf 'Debut E2E fixture one\n' > "$fixture_dir/one.txt"
printf 'Debut E2E fixture two\n' > "$fixture_dir/two.txt"
open -na TextEdit "$fixture_dir/one.txt"
open -na TextEdit "$fixture_dir/two.txt"
sleep 2

echo "Launching Debut..."
open "$app_path"
sleep 4

.build/release/DebutE2E
