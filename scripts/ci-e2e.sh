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

app_path="/Applications/Debut.app"
system_tcc_db="/Library/Application Support/com.apple.TCC/TCC.db"
user_tcc_db="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
fixture_dir="${RUNNER_TEMP}/debut-e2e-fixtures"
screen_capture_approvals="$HOME/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist"

cleanup() {
    pkill -f "Debut.app" 2>/dev/null || true
    pkill -x TextEdit 2>/dev/null || true
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
./scripts/build-app.sh
sudo rm -rf "$app_path"
sudo cp -R .build/Debut.app "$app_path"

echo "Granting Accessibility access inside the disposable runner..."
requirement=$(codesign -d -r- "$app_path" 2>&1 | awk -F ' => ' '/designated/{print $2}')
csreq_hex=$(printf '%s' "$requirement" | csreq -r- -b /dev/stdout | xxd -p | tr -d '\n')
timestamp=$(date +%s)
sudo sqlite3 "$system_tcc_db" "INSERT OR REPLACE INTO access VALUES(\
'kTCCServiceAccessibility','com.thomplth.Debut',0,2,4,1,X'$csreq_hex',NULL,0,'UNUSED',NULL,0,$timestamp,NULL,NULL,'UNUSED',$timestamp);"
sudo sqlite3 "$system_tcc_db" "INSERT OR REPLACE INTO access VALUES(\
'kTCCServiceScreenCapture','com.thomplth.Debut',0,2,4,1,X'$csreq_hex',NULL,0,'UNUSED',NULL,0,$timestamp,NULL,NULL,'UNUSED',$timestamp);"
sqlite3 "$user_tcc_db" "INSERT OR REPLACE INTO access VALUES(\
'kTCCServiceScreenCapture','com.thomplth.Debut',0,2,4,1,X'$csreq_hex',NULL,0,'UNUSED',NULL,0,$timestamp,NULL,NULL,'UNUSED',$timestamp);"
sudo killall tccd 2>/dev/null || true

echo "Preparing deterministic fixture windows..."
rm -rf "$HOME/Library/Application Support/Debut"
defaults write com.thomplth.Debut hasCompletedOnboarding -bool true
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
