#!/bin/bash
set -euo pipefail

# Captures the README media inside the Tart guest, so the screenshots show a real macOS
# desktop with real windows rather than the developer's own. Reuses the E2E VM: it is
# already provisioned, and the capture leaves nothing behind that a later E2E run cares
# about, since that run reinstalls the app and resets Debut's state anyway.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VM_NAME="${DEBUT_TART_VM:-debut-e2e-tahoe}"
SHARE_DIR="${DEBUT_TART_SHARE:-$HOME/Library/Caches/Debut/TartE2E}"
SSH_KEY="$SHARE_DIR/id_ed25519"
KNOWN_HOSTS="$SHARE_DIR/known_hosts"
MEDIA_DIR="$PROJECT_DIR/docs/media"
DISPLAY_MODE="${DEBUT_DEMO_DISPLAY:-1440x900}"
GIF_WIDTH="${DEBUT_DEMO_GIF_WIDTH:-1440}"
STILL_WIDTH="${DEBUT_DEMO_STILL_WIDTH:-820}"

usage() {
    cat <<EOF
Usage: scripts/demo-capture.sh [--clips a,b,c] [--keep-raw]

Records the README media in the Tart guest and converts it into docs/media.
Requires the VM from scripts/tart-e2e.sh prepare, plus ffmpeg on the host.
The default clip is command-tab; use --clips to select other demo sequences.

Overrides: DEBUT_TART_VM, DEBUT_TART_SHARE, DEBUT_DEMO_DISPLAY, DEBUT_DEMO_GIF_WIDTH,
           DEBUT_DEMO_STILL_WIDTH
EOF
}

CLIPS="command-tab"
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

echo "Building Debut and the demo driver on the host..."
"$PROJECT_DIR/scripts/build-app.sh"
TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault /usr/bin/swift build -c release --product DebutDemo \
    --package-path "$PROJECT_DIR"

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
# The guest browses the project's own doc site, which needs no network and is honest about
# what is on screen.
/usr/bin/ditto -c -k --keepParent "$PROJECT_DIR/docs/html" "$SHARE_DIR/$DOCS_ARTIFACT"

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
# The cover is a tightly framed capture of the actual overlay window on a plain light canvas.
# Keep its text lossless in PNG; onboarding stills retain their existing JPEG format.
for still in "$RAW_DIR"/*.png; do
    [[ -e "$still" ]] || continue
    name="$(basename "${still%.png}")"
    if [[ "$name" == overlay ]]; then
        cp "$still" "$MEDIA_DIR/overlay.png"
        echo "  overlay.png $(du -h "$MEDIA_DIR/overlay.png" | cut -f1)"
        continue
    fi
    crop=""
    case "$name" in
        onboarding-workspace) crop="crop=1000:630:940:740," ;;
        onboarding-previews|onboarding-no-previews) crop="crop=1340:430:770:715," ;;
    esac
    ffmpeg -loglevel error -y -i "$still" \
        -vf "${crop}scale=$((STILL_WIDTH * 2)):-1:flags=lanczos" -q:v 3 "$MEDIA_DIR/$name.jpg"
    echo "  $name.jpg $(du -h "$MEDIA_DIR/$name.jpg" | cut -f1)"
done

# One palette and ordered dithering keep unchanged regions identical. Drop duplicate frames
# while retaining their timestamps, then encode only changed rectangles with transparency.
# This retains readable UI at 1440px without paying for a full frame on every tick.
for clip in "$RAW_DIR"/*.mov; do
    [[ -e "$clip" ]] || continue
    name="$(basename "${clip%.mov}")"
    [[ "$name" == onboarding-* ]] && continue
    ffmpeg -loglevel error -y -i "$clip" \
        -vf "fps=15,scale=$GIF_WIDTH:-1:flags=lanczos,mpdecimate,split[a][b];[a]palettegen=max_colors=256:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
        -fps_mode vfr -gifflags +transdiff+offsetting -loop 0 -final_delay 180 "$MEDIA_DIR/$name.gif"
    echo "  $name.gif $(du -h "$MEDIA_DIR/$name.gif" | cut -f1)"
done

if [[ -f "$RAW_DIR/onboarding-native.mov" && -f "$RAW_DIR/onboarding-instant.mov" ]]; then
    ffmpeg -loglevel error -y -i "$RAW_DIR/onboarding-native.mov" -i "$RAW_DIR/onboarding-instant.mov" \
        -filter_complex '[0:v]fps=30,scale=640:400,tpad=stop_mode=clone:stop_duration=5,trim=duration=4.8,setpts=PTS-STARTPTS[a];[1:v]fps=30,scale=640:400,tpad=stop_mode=clone:stop_duration=5,trim=duration=4.8,setpts=PTS-STARTPTS[b];[a][b]hstack=inputs=2[v]' \
        -map '[v]' -c:v libx264 -crf 22 -pix_fmt yuv420p -movflags +faststart "$MEDIA_DIR/onboarding-speed.mp4"
    ffmpeg -loglevel error -y -ss 0.9 -i "$MEDIA_DIR/onboarding-speed.mp4" -frames:v 1 "$MEDIA_DIR/onboarding-speed.jpg"
fi

if (( KEEP_RAW )); then
    echo "Raw captures kept at $RAW_DIR"
else
    rm -rf "$RAW_DIR"
fi
echo "Media written to $MEDIA_DIR"
