#!/bin/bash
set -euo pipefail

# Captures the README media inside the Tart guest, so the screenshots show a real macOS
# desktop with real windows rather than the developer's own. Reuses the E2E VM: it is
# already provisioned, and the capture leaves nothing behind that a later E2E run cares
# about, since that run reinstalls the app and resets Debut's state anyway.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/tart-queue.sh
source "$SCRIPT_DIR/tart-queue.sh"
VM_NAME="${DEBUT_TART_VM:-debut-e2e-tahoe}"
SHARE_DIR="${DEBUT_TART_SHARE:-$HOME/Library/Caches/Debut/TartE2E}"
SSH_KEY="$SHARE_DIR/id_ed25519"
KNOWN_HOSTS="$SHARE_DIR/known_hosts"
MEDIA_DIR="$PROJECT_DIR/docs/media"
DISPLAY_MODE="${DEBUT_DEMO_DISPLAY:-1440x900}"
GIF_WIDTH="${DEBUT_DEMO_GIF_WIDTH:-1440}"
GIF_COLORS="${DEBUT_DEMO_GIF_COLORS:-128}"
STILL_WIDTH="${DEBUT_DEMO_STILL_WIDTH:-820}"

usage() {
    cat <<EOF
Usage: scripts/demo-capture.sh [--clips a,b,c] [--keep-raw]

Records the README media in the Tart guest and converts it into docs/media.
Requires the VM from scripts/tart-e2e.sh prepare, plus ffmpeg on the host.
The default captures the cover and all four README demos.

Overrides: DEBUT_TART_VM, DEBUT_TART_SHARE, DEBUT_DEMO_DISPLAY, DEBUT_DEMO_GIF_WIDTH,
           DEBUT_DEMO_GIF_COLORS, DEBUT_DEMO_STILL_WIDTH
EOF
}

CLIPS="cover,command-tab,organize-windows,option-tab,faster-space-switching"
KEEP_RAW=0
while (( $# > 0 )); do
    case "$1" in
        --clips) CLIPS="${2:?missing clip list}"; shift 2 ;;
        --keep-raw) KEEP_RAW=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

for tool in tart ffmpeg; do
    command -v "$tool" >/dev/null 2>&1 || { echo "$tool is required." >&2; exit 1; }
done
tart list --source local --quiet | grep -Fqx "$VM_NAME" || {
    echo "Tart VM $VM_NAME does not exist. Run scripts/tart-e2e.sh prepare first." >&2
    exit 1
}

# Pin the visualizer so captures are reproducible. It is never installed on the host.
mkdir -p "$SHARE_DIR"
if [[ ! -f "$SHARE_DIR/KeyCastr-0.11.1.app.zip" ]]; then
    curl -fL https://github.com/keycastr/keycastr/releases/download/v0.11.1/KeyCastr.app.zip \
        -o "$SHARE_DIR/KeyCastr-0.11.1.app.zip"
fi

echo "Building Debut and the demo driver on the host..."
"$PROJECT_DIR/scripts/build-app.sh"
TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault /usr/bin/swift build -c release --product DebutDemo \
    --package-path "$PROJECT_DIR"

# The capture shares the E2E guest and share directory, so wait for any run already using them
# before replacing staged artifacts.
trap tart_queue_leave EXIT
trap 'exit 130' INT TERM
tart_queue_enter "demo-capture $(basename "$PROJECT_DIR")"

ARTIFACT_ID="$(date +%s)-$$"
APP_ARTIFACT="DebutDemo-$ARTIFACT_ID.app.zip"
DRIVER_ARTIFACT="DebutDemoDriver-$ARTIFACT_ID"
PROVISION_ARTIFACT="DebutDemoProvisioner-$ARTIFACT_ID"
DOCS_ARTIFACT="DebutDemoDocs-$ARTIFACT_ID.zip"
GUEST_ARTIFACT="demo-capture-guest-$ARTIFACT_ID.sh"

mkdir -p "$SHARE_DIR"
shopt -s nullglob
old=( "$SHARE_DIR"/DebutDemo-*.app.zip "$SHARE_DIR"/DebutDemoDriver-* "$SHARE_DIR"/DebutDemoProvisioner-* "$SHARE_DIR"/DebutDemoDocs-*.zip "$SHARE_DIR"/demo-capture-guest-*.sh )
shopt -u nullglob
(( ${#old[@]} > 0 )) && rm -f -- "${old[@]}"

/usr/bin/ditto -c -k --keepParent "$PROJECT_DIR/.build/Debut.app" "$SHARE_DIR/$APP_ARTIFACT"
/usr/bin/install -m 755 "$PROJECT_DIR/.build/release/DebutDemo" "$SHARE_DIR/$DRIVER_ARTIFACT"
/usr/bin/install -m 755 "$PROJECT_DIR/.build/release/DebutE2E" "$SHARE_DIR/$PROVISION_ARTIFACT"
/usr/bin/install -m 755 "$SCRIPT_DIR/demo-capture-guest.sh" "$SHARE_DIR/$GUEST_ARTIFACT"
# Static demo pages keep capture content reproducible and independent of documentation.
/usr/bin/ditto -c -k --keepParent "$PROJECT_DIR/Tests/Fixtures/Demo/html" "$SHARE_DIR/$DOCS_ARTIFACT"

if ! tart exec "$VM_NAME" /usr/bin/true >/dev/null 2>&1; then
    echo "Starting $VM_NAME headlessly..."
    nohup tart run --no-graphics --no-audio --no-clipboard --no-pointer --no-keyboard \
        --dir="$SHARE_DIR" "$VM_NAME" >"$SHARE_DIR/tart-vm.log" 2>&1 </dev/null &
    for _ in {1..90}; do
        tart exec "$VM_NAME" /usr/bin/true >/dev/null 2>&1 && break
        sleep 2
    done
fi
tart exec "$VM_NAME" /usr/bin/true >/dev/null 2>&1 || {
    echo "The guest did not become ready." >&2
    exit 1
}

[[ -f "$SSH_KEY" ]] || ssh-keygen -q -t ed25519 -N "" -C "debut-demo" -f "$SSH_KEY"
tart exec "$VM_NAME" /bin/bash -c '
    set -e
    umask 077
    mkdir -p "$HOME/.ssh"
    touch "$HOME/.ssh/authorized_keys"
    grep -qxF "$1" "$HOME/.ssh/authorized_keys" || printf "%s\n" "$1" >> "$HOME/.ssh/authorized_keys"
' _ "$(<"$SSH_KEY.pub")"

echo "Capturing inside $VM_NAME..."
guest_arguments=( "/Volumes/My Shared Files/$GUEST_ARTIFACT" "$APP_ARTIFACT" "$DRIVER_ARTIFACT"
    "$DOCS_ARTIFACT" "$DISPLAY_MODE" "$PROVISION_ARTIFACT" )
[[ -n "$CLIPS" ]] && guest_arguments+=( --clips "$CLIPS" )
printf -v quoted_arguments ' %q' "${guest_arguments[@]}"
remote_command="/bin/bash$quoted_arguments"
if guest_ip="$(tart ip "$VM_NAME" --wait 15 2>/dev/null)"; then
    ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$KNOWN_HOSTS" "admin@$guest_ip" "$remote_command"
else
    # vsock works without DHCP. Enter through the guest's loopback SSH server so capture
    # retains the same TCC responsibility as normal SSH, independent of the guest agent.
    tart exec "$VM_NAME" /bin/bash -c '
        set -e
        umask 077
        key="$HOME/.ssh/id_ed25519_debut_demo"
        [[ -f "$key" ]] || ssh-keygen -q -t ed25519 -N "" -C "debut-demo-loopback" -f "$key"
        grep -qxF "$(<"$key.pub")" "$HOME/.ssh/authorized_keys" || cat "$key.pub" >> "$HOME/.ssh/authorized_keys"
        exec ssh -i "$key" -o BatchMode=yes -o StrictHostKeyChecking=accept-new admin@127.0.0.1 "$1"
    ' _ "$remote_command"
fi

RAW_DIR="$SHARE_DIR/media"
[[ -d "$RAW_DIR" ]] || { echo "The guest produced no media at $RAW_DIR." >&2; exit 1; }

echo "Converting..."
mkdir -p "$MEDIA_DIR"
# The cover preserves the actual overlay alpha and leaves margin around its shadow.
# Onboarding uses the same lossless, alpha-preserving framing.
for still in "$RAW_DIR"/*.png; do
    [[ -e "$still" ]] || continue
    name="$(basename "${still%.png}")"
    if [[ "$name" == overlay || "$name" == overlay-dark || "$name" == onboarding-* ]]; then
        cp "$still" "$MEDIA_DIR/$name.png"
        echo "  $name.png $(du -h "$MEDIA_DIR/$name.png" | cut -f1)"
        continue
    fi
    ffmpeg -loglevel error -y -i "$still" \
        -vf "scale=$((STILL_WIDTH * 2)):-1:flags=lanczos" -q:v 3 "$MEDIA_DIR/$name.jpg"
    echo "  $name.jpg $(du -h "$MEDIA_DIR/$name.jpg" | cut -f1)"
done

# One palette and ordered dithering keep unchanged regions identical. Drop duplicate frames
# while retaining their timestamps, then encode only changed rectangles with transparency.
# This retains readable UI at 1440px without paying for a full frame on every tick.
for clip in "$RAW_DIR"/*.mov; do
    [[ -e "$clip" ]] || continue
    name="$(basename "${clip%.mov}")"
    [[ "$name" == onboarding-* || "$name" == speed-* ]] && continue
    ffmpeg -loglevel error -y -i "$clip" \
        -vf "fps=15,scale=$GIF_WIDTH:-1:flags=lanczos,mpdecimate,split[a][b];[a]palettegen=max_colors=$GIF_COLORS:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
        -fps_mode vfr -gifflags +transdiff+offsetting -loop 0 -final_delay 180 "$MEDIA_DIR/$name.gif"
    echo "  $name.gif $(du -h "$MEDIA_DIR/$name.gif" | cut -f1)"
done

if [[ -f "$RAW_DIR/speed-native.mov" && -f "$RAW_DIR/speed-instant.mov" ]]; then
    ffmpeg -loglevel error -y -i "$RAW_DIR/speed-native.mov" -i "$RAW_DIR/speed-instant.mov" \
        -filter_complex "[0:v]fps=15,scale=720:450:flags=lanczos,setpts=PTS-STARTPTS,pad=720:498:0:48:color=0x15171b,drawtext=text='macOS default':fontfile=/System/Library/Fonts/Helvetica.ttc:fontsize=26:fontcolor=white:x=(w-tw)/2:y=10[a];[1:v]fps=15,scale=720:450:flags=lanczos,setpts=PTS-STARTPTS,pad=720:498:0:48:color=0x15171b,drawtext=text='Instant':fontfile=/System/Library/Fonts/Helvetica.ttc:fontsize=26:fontcolor=white:x=(w-tw)/2:y=10[b];[a][b]hstack=inputs=2,mpdecimate,split[c][d];[c]palettegen=max_colors=$GIF_COLORS:stats_mode=diff[p];[d][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
        -fps_mode vfr -gifflags +transdiff+offsetting -loop 0 -final_delay 180 "$MEDIA_DIR/faster-space-switching.gif"
fi

if [[ -f "$RAW_DIR/onboarding-speed-native.mov" && -f "$RAW_DIR/onboarding-speed-instant.mov" ]]; then
    # Keep both real-time timelines intact; only align the start of each recording.
    # ScreenCaptureKit omits idle frames; hold the ending desktop to a common 5 seconds.
    # Full-color H.264 preserves far more detail and motion than the README GIF.
    ffmpeg -loglevel error -y -i "$RAW_DIR/onboarding-speed-native.mov" -i "$RAW_DIR/onboarding-speed-instant.mov" \
        -filter_complex "[0:v]setpts=PTS-STARTPTS,fps=60,scale=1440:900:flags=lanczos,pad=1440:996:0:96:color=0x15171b,drawtext=text='macOS default':fontfile=/System/Library/Fonts/Helvetica.ttc:fontsize=46:fontcolor=white:x=(w-tw)/2:y=20,tpad=stop_mode=clone:stop_duration=5[a];[1:v]setpts=PTS-STARTPTS,fps=60,scale=1440:900:flags=lanczos,pad=1440:996:0:96:color=0x15171b,drawtext=text='Debut Instant':fontfile=/System/Library/Fonts/Helvetica.ttc:fontsize=46:fontcolor=white:x=(w-tw)/2:y=20,tpad=stop_mode=clone:stop_duration=5[b];[a][b]hstack=inputs=2:shortest=1,trim=duration=5[v]" \
        -map '[v]' -an -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p -movflags +faststart \
        "$MEDIA_DIR/onboarding-speed.mp4"
    ffmpeg -loglevel error -y -i "$MEDIA_DIR/onboarding-speed.mp4" -frames:v 1 "$MEDIA_DIR/onboarding-speed.png"
    echo "  onboarding-speed.mp4 $(du -h "$MEDIA_DIR/onboarding-speed.mp4" | cut -f1)"
fi

if (( KEEP_RAW )); then
    echo "Raw captures kept at $RAW_DIR"
else
    rm -rf "$RAW_DIR"
fi
echo "Media written to $MEDIA_DIR"
