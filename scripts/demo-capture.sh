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
GIF_WIDTH="${DEBUT_DEMO_GIF_WIDTH:-760}"
STILL_WIDTH="${DEBUT_DEMO_STILL_WIDTH:-820}"

usage() {
    cat <<EOF
Usage: scripts/demo-capture.sh [--clips a,b,c] [--keep-raw]

Records the README media in the Tart guest and converts it into docs/media.
Requires the VM from scripts/tart-e2e.sh prepare, plus ffmpeg on the host.

Overrides: DEBUT_TART_VM, DEBUT_TART_SHARE, DEBUT_DEMO_DISPLAY, DEBUT_DEMO_GIF_WIDTH,
           DEBUT_DEMO_STILL_WIDTH
EOF
}

CLIPS=""
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
DOCS_ARTIFACT="DebutDemoDocs-$ARTIFACT_ID.zip"
GUEST_ARTIFACT="demo-capture-guest-$ARTIFACT_ID.sh"

mkdir -p "$SHARE_DIR"
shopt -s nullglob
old=( "$SHARE_DIR"/DebutDemo-*.app.zip "$SHARE_DIR"/DebutDemoDriver-* "$SHARE_DIR"/DebutDemoDocs-*.zip "$SHARE_DIR"/demo-capture-guest-*.sh )
shopt -u nullglob
(( ${#old[@]} > 0 )) && rm -f -- "${old[@]}"

/usr/bin/ditto -c -k --keepParent "$PROJECT_DIR/.build/Debut.app" "$SHARE_DIR/$APP_ARTIFACT"
/usr/bin/install -m 755 "$PROJECT_DIR/.build/release/DebutDemo" "$SHARE_DIR/$DRIVER_ARTIFACT"
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
guest_ip="$(tart ip "$VM_NAME")"
printf -v remote_command '/bin/bash %q %q %q %q %q' \
    "/Volumes/My Shared Files/$GUEST_ARTIFACT" "$APP_ARTIFACT" "$DRIVER_ARTIFACT" \
    "$DOCS_ARTIFACT" "$DISPLAY_MODE"
[[ -n "$CLIPS" ]] && printf -v remote_command '%s --clips %q' "$remote_command" "$CLIPS"
ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$KNOWN_HOSTS" "admin@$guest_ip" "$remote_command"

RAW_DIR="$SHARE_DIR/media"
[[ -d "$RAW_DIR" ]] || { echo "The guest produced no media at $RAW_DIR." >&2; exit 1; }

echo "Converting..."
mkdir -p "$MEDIA_DIR"
# The guest captures at the full 2880x1800 backing scale, which is a 4.7 MB PNG for something
# the README displays at 820 points. JPEG at twice the display width is 277 KB and, on a
# screenshot this photographic, indistinguishable — the stages are translucent glass over a
# wallpaper, not flat UI that would ring.
for still in "$RAW_DIR"/*.png; do
    [[ -e "$still" ]] || continue
    name="$(basename "${still%.png}")"
    ffmpeg -loglevel error -y -i "$still" \
        -vf "scale=$((STILL_WIDTH * 2)):-1:flags=lanczos" -q:v 3 "$MEDIA_DIR/$name.jpg"
    echo "  $name.jpg $(du -h "$MEDIA_DIR/$name.jpg" | cut -f1)"
done

# One shared palette per clip: the stages are translucent over a photographic wallpaper, and
# a per-frame palette makes that gradient crawl. `stats_mode=diff` spends that palette on the
# moving stages rather than the static desktop behind them, and ordered dithering keeps the
# still regions byte-identical between frames — error diffusion sprays them with noise that no
# GIF encoder can delta away, which is what made the first cut of these 14 MB.
for clip in "$RAW_DIR"/*.mov; do
    [[ -e "$clip" ]] || continue
    name="$(basename "${clip%.mov}")"
    ffmpeg -loglevel error -y -i "$clip" \
        -vf "fps=15,scale=$GIF_WIDTH:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
        -loop 0 "$MEDIA_DIR/$name.gif"
    echo "  $name.gif $(du -h "$MEDIA_DIR/$name.gif" | cut -f1)"
done

if (( KEEP_RAW )); then
    echo "Raw captures kept at $RAW_DIR"
else
    rm -rf "$RAW_DIR"
fi
echo "Media written to $MEDIA_DIR"
