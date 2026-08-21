#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VM_NAME="${DEBUT_TART_VM:-debut-e2e-tahoe}"
VM_IMAGE="ghcr.io/cirruslabs/macos-tahoe-base:latest"
SHARE_DIR="${DEBUT_TART_SHARE:-$HOME/Library/Caches/Debut/TartE2E}"
VM_LOG="$SHARE_DIR/tart-vm.log"
SSH_KEY="$SHARE_DIR/id_ed25519"
KNOWN_HOSTS="$SHARE_DIR/known_hosts"
APP_ARTIFACT=""
E2E_ARTIFACT=""
GUEST_ARTIFACT=""

usage() {
    cat <<EOF
Usage: scripts/tart-e2e.sh <prepare|run|run-all|stop|status>

  prepare  Clone and configure the free Tahoe VM (one-time, about 27 GB download)
  run      Run the checks that are stable under virtualization; skip the drag gestures
  run-all  Attempt every check, including the drag gestures Tart cannot deliver
  stop     Stop the warm guest VM
  status   Show the VM configuration and current IP address

Overrides: DEBUT_TART_VM, DEBUT_TART_SHARE
EOF
}

require_tart() {
    if ! command -v tart >/dev/null 2>&1; then
        echo "Tart is required. Install the official release with:" >&2
        echo "  brew install cirruslabs/cli/tart" >&2
        exit 1
    fi
}

vm_exists() {
    tart list --source local --quiet | grep -Fqx "$VM_NAME"
}

prepare_vm() {
    if vm_exists; then
        echo "Tart VM already exists: $VM_NAME"
    else
        echo "Cloning $VM_IMAGE as $VM_NAME..."
        tart clone "$VM_IMAGE" "$VM_NAME"
    fi

    tart set "$VM_NAME" --cpu 6 --memory 8192 --display 1440x900
    tart get "$VM_NAME"
}

stage_build() {
    local ARTIFACT_ID
    local old_artifacts=()
    echo "Building Debut and the E2E executable on the host..."
    "$PROJECT_DIR/scripts/build-app.sh"

    mkdir -p "$SHARE_DIR"
    rm -rf "$SHARE_DIR/results"
    shopt -s nullglob
    old_artifacts=(
        "$SHARE_DIR"/Debut-*.app.zip
        "$SHARE_DIR"/DebutE2E-*
        "$SHARE_DIR"/tart-e2e-guest-*.sh
    )
    shopt -u nullglob
    if (( ${#old_artifacts[@]} > 0 )); then
        rm -f -- "${old_artifacts[@]}"
    fi
    ARTIFACT_ID="$(date +%s)-$$"
    APP_ARTIFACT="Debut-$ARTIFACT_ID.app.zip"
    E2E_ARTIFACT="DebutE2E-$ARTIFACT_ID"
    GUEST_ARTIFACT="tart-e2e-guest-$ARTIFACT_ID.sh"
    /usr/bin/ditto -c -k --keepParent "$PROJECT_DIR/.build/Debut.app" "$SHARE_DIR/$APP_ARTIFACT"
    /usr/bin/install -m 755 "$PROJECT_DIR/.build/release/DebutE2E" "$SHARE_DIR/$E2E_ARTIFACT"
    /usr/bin/install -m 755 "$PROJECT_DIR/scripts/tart-e2e-guest.sh" "$SHARE_DIR/$GUEST_ARTIFACT"
}

guest_is_ready() {
    tart exec "$VM_NAME" /usr/bin/true >/dev/null 2>&1
}

start_vm() {
    if guest_is_ready; then
        echo "Reusing warm Tart VM: $VM_NAME"
        return
    fi

    echo "Starting $VM_NAME headlessly; host input devices are not attached..."
    mkdir -p "$SHARE_DIR"
    nohup tart run --no-graphics --no-audio --no-clipboard --no-pointer --no-keyboard --dir="$SHARE_DIR" "$VM_NAME" >"$VM_LOG" 2>&1 </dev/null &

    for _ in {1..90}; do
        if guest_is_ready; then
            echo "Guest agent is ready."
            return
        fi
        sleep 2
    done

    echo "The guest did not become ready within 180 seconds. VM log: $VM_LOG" >&2
    exit 1
}

prepare_ssh() {
    local public_key
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
}

run_e2e() {
    local e2e_mode="$1"
    local guest_ip remote_command ssh_status
    if ! vm_exists; then
        echo "Tart VM $VM_NAME does not exist. Run scripts/tart-e2e.sh prepare first." >&2
        exit 1
    fi

    stage_build
    start_vm
    prepare_ssh

    echo "Running the full E2E suite inside $VM_NAME..."
    guest_ip="$(tart ip "$VM_NAME")"
    printf -v remote_command '/bin/bash %q %q %q %q' \
        "/Volumes/My Shared Files/$GUEST_ARTIFACT" "$APP_ARTIFACT" "$E2E_ARTIFACT" "$e2e_mode"
    set +e
    ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN_HOSTS" "admin@$guest_ip" "$remote_command" 2>&1 | tee "$SHARE_DIR/e2e-latest.log"
    ssh_status="${PIPESTATUS[0]}"
    set -e
    echo "Guest evidence: $SHARE_DIR/results"
    return "$ssh_status"
}

show_status() {
    if ! vm_exists; then
        echo "Tart VM not prepared: $VM_NAME"
        return
    fi
    tart get "$VM_NAME"
    if guest_is_ready; then
        echo "IP: $(tart ip "$VM_NAME")"
    else
        echo "State: stopped"
    fi
}

require_tart

case "${1:-}" in
    prepare) prepare_vm ;;
    run) run_e2e virtualized ;;
    run-all) run_e2e all ;;
    stop) tart stop "$VM_NAME" ;;
    status) show_status ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
esac
