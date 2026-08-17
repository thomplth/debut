#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VM_NAME="${DEBUT_TART_VM:-debut-e2e-tahoe}"
SHARE_DIR="${DEBUT_TART_SHARE:-$HOME/Library/Caches/Debut/TartE2E}"
LAB_SHARE="$SHARE_DIR/glass-lab"
SSH_KEY="$SHARE_DIR/id_ed25519"
KNOWN_HOSTS="$SHARE_DIR/known_hosts"
VNC_ENV="$HOME/Library/Caches/Debut/TartVNC"
VNC_LOG="$LAB_SHARE/tart-vnc.log"

if ! tart list --source local --quiet | grep -Fqx "$VM_NAME"; then
    echo "Tart VM $VM_NAME is not prepared. Run scripts/tart-e2e.sh prepare first." >&2
    exit 1
fi

"$SCRIPT_DIR/build-glass-lab.sh"
rm -rf "$LAB_SHARE/artifacts" "$LAB_SHARE/results"
mkdir -p "$LAB_SHARE/artifacts" "$LAB_SHARE/results"
cp "$PROJECT_DIR"/.build/glass-lab-builds/*.app.zip "$LAB_SHARE/artifacts/"
cp "$SCRIPT_DIR/tart-glass-lab-guest.sh" "$LAB_SHARE/tart-glass-lab-guest.sh"

if [[ ! -x "$VNC_ENV/bin/vncdo" ]]; then
    python3 -m venv "$VNC_ENV"
    "$VNC_ENV/bin/pip" install -q vncdotool
fi

if tart exec "$VM_NAME" /usr/bin/true >/dev/null 2>&1; then
    tart stop "$VM_NAME"
fi

rm -f "$VNC_LOG"
tart run --no-graphics --vnc-experimental --no-audio --no-clipboard \
    --dir="$SHARE_DIR" "$VM_NAME" >"$VNC_LOG" 2>&1 &
tart_pid=$!

cleanup() {
    set +e
    if [[ -n "${guest_ip:-}" ]]; then
        ssh -i "$SSH_KEY" -o BatchMode=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
            "admin@$guest_ip" '/bin/bash "/Volumes/My Shared Files/glass-lab/tart-glass-lab-guest.sh" cleanup' \
            >/dev/null 2>&1
    fi
    kill "$tart_pid" >/dev/null 2>&1 || true
    wait "$tart_pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for _ in {1..90}; do
    grep -q 'VNC server is running at' "$VNC_LOG" 2>/dev/null && break
    sleep 1
done
vnc_url="$(sed -n 's/.*\(vnc:\/\/.*\)/\1/p' "$VNC_LOG" | tail -1)"
if [[ -z "$vnc_url" ]]; then
    echo "Tart did not publish a VNC endpoint. Log: $VNC_LOG" >&2
    exit 1
fi
vnc_password="$(sed -E 's#vnc://:([^@]+)@.*#\1#' <<< "$vnc_url")"
vnc_port="$(sed -E 's#.*:([0-9]+)$#\1#' <<< "$vnc_url")"

for _ in {1..90}; do
    tart exec "$VM_NAME" /usr/bin/true >/dev/null 2>&1 && break
    sleep 2
done

if [[ ! -f "$SSH_KEY" ]]; then
    ssh-keygen -q -t ed25519 -N "" -C "debut-tart-e2e" -f "$SSH_KEY"
fi
public_key="$(<"$SSH_KEY.pub")"
tart exec "$VM_NAME" /bin/bash -c '
    set -e
    umask 077
    mkdir -p "$HOME/.ssh"
    touch "$HOME/.ssh/authorized_keys"
    grep -qxF "$1" "$HOME/.ssh/authorized_keys" || printf "%s\n" "$1" >> "$HOME/.ssh/authorized_keys"
' _ "$public_key"

guest_ip="$(tart ip "$VM_NAME")"
remote() {
    ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$KNOWN_HOSTS" "admin@$guest_ip" "$@"
}
guest_script='/bin/bash "/Volumes/My Shared Files/glass-lab/tart-glass-lab-guest.sh"'
remote "$guest_script prepare"

capture() {
    local destination="$1"
    PYTHONWARNINGS=ignore "$VNC_ENV/bin/vncdo" -s "127.0.0.1::$vnc_port" -p "$vnc_password" \
        --nocursor capture "$destination" >/dev/null
    "$PROJECT_DIR/.build/release/DebutGlassLab" --validate-capture "$destination"
}

states=(normal reduce-transparency increase-contrast reduce-and-contrast)
appearances=(light dark)

for appearance in "${appearances[@]}"; do
    remote "$guest_script appearance $appearance"
    for state in "${states[@]}"; do
        remote "$guest_script accessibility $state"
        destination="$LAB_SHARE/results/$appearance/$state"
        mkdir -p "$destination"

        remote "$guest_script native 3" &
        native_pid=$!
        sleep 1
        capture "$destination/native-command-tab.png"
        wait "$native_pid"

        for app in "$PROJECT_DIR"/.build/glass-lab-builds/DebutGlassLab-*.app; do
            artifact="$(basename "$app" .app)"
            remote "$guest_script launch $artifact $appearance"
            sleep 1
            capture "$destination/$artifact.png"
            remote "$guest_script stop"
        done
    done
done

echo "Captured and validated 104 VM framebuffer images in $LAB_SHARE/results"
