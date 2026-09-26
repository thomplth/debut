#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/tart-queue.sh
source "$SCRIPT_DIR/tart-queue.sh"
# shellcheck source=scripts/tart-run-report.sh
source "$SCRIPT_DIR/tart-run-report.sh"
VM_NAME="${DEBUT_TART_VM:-debut-e2e-tahoe}"
VM_IMAGE="ghcr.io/cirruslabs/macos-tahoe-base:latest"
SHARE_DIR="${DEBUT_TART_SHARE:-$HOME/Library/Caches/Debut/TartE2E}"
VM_LOG="$SHARE_DIR/tart-vm.log"
SSH_KEY="$SHARE_DIR/id_ed25519"
KNOWN_HOSTS="$SHARE_DIR/known_hosts"
RUN_LOCK="$SHARE_DIR/tart-e2e.lock"
RUN_LOCK_HELD=false
RUNS_DIR="$SHARE_DIR/runs"
KEEP_RUNS="${DEBUT_TART_KEEP_RUNS:-5}"
RUN_CANCELED=false
RESULTS_COLLECTED=false
SOURCE_IDENTITY='{}'
BUILD_CPU_SECONDS=""
SUITE_VM_CPU_SECONDS=""
APP_ARTIFACT=""
APP_BUNDLE=""
E2E_ARTIFACT=""
GUEST_ARTIFACT=""
DURATION_PROFILE=""
GALLERY_CAPTURE=on

usage() {
    cat <<EOF
Usage: scripts/tart-e2e.sh <prepare|run|stop|status>
       scripts/tart-e2e.sh run [--duration-profile ordinary|full] [--no-gallery]

  prepare  Clone and configure the free Tahoe VM (one-time, about 27 GB download)
  run      Run every check in the headless guest
  stop     Stop the warm guest VM (refused while another task's run holds the queue;
           --force overrides)
  status   Show the VM configuration, guest-agent readiness and the run queue

Run options:
  --duration-profile ordinary|full
           Window-move durations to sweep. ordinary runs nine values, including every
           value from 40 through 80 ms; full runs all 41. Defaults to
           DEBUT_E2E_DURATION_PROFILE, or full when that is unset.
  --no-gallery
           Skip the glass screenshot gallery. Rendering assertions still run.

Runs wait in arrival order for the one local guest, across every checkout and
override. Interrupting a waiting run leaves the queue without touching the VM.

Each run keeps its log, guest results and a report.json with phase timings, source
identity and check results in \$DEBUT_TART_SHARE/runs/<run-id>. The newest
DEBUT_TART_KEEP_RUNS (default 5) runs and as many unsuccessful ones are kept.

Overrides: DEBUT_TART_VM, DEBUT_TART_SHARE, DEBUT_E2E_DURATION_PROFILE,
           DEBUT_TART_QUEUE_DIR, DEBUT_TART_KEEP_RUNS
EOF
}

# Parsed before anything touches Tart, so a bad request cannot boot, build or mutate the guest.
parse_run_options() {
    DURATION_PROFILE="${DEBUT_E2E_DURATION_PROFILE:-full}"
    GALLERY_CAPTURE=on
    while (( $# > 0 )); do
        case "$1" in
            --duration-profile)
                if (( $# < 2 )); then
                    echo "--duration-profile needs a value: ordinary or full." >&2
                    exit 2
                fi
                DURATION_PROFILE="$2"
                shift 2
                ;;
            --no-gallery) GALLERY_CAPTURE=off; shift ;;
            *)
                echo "Unknown run option: $1" >&2
                usage >&2
                exit 2
                ;;
        esac
    done
    if [[ "$DURATION_PROFILE" != ordinary && "$DURATION_PROFILE" != full ]]; then
        echo "The duration profile must be ordinary or full, not '$DURATION_PROFILE'." >&2
        exit 2
    fi
}

guest_command() {
    local command
    printf -v command '/bin/bash %q %q %q %q %q' \
        "/Volumes/My Shared Files/$GUEST_ARTIFACT" "$APP_ARTIFACT" "$E2E_ARTIFACT" \
        "$DURATION_PROFILE" "$GALLERY_CAPTURE"
    printf '%s\n' "$command"
}

require_tart() {
    if ! command -v tart >/dev/null 2>&1; then
        echo "Tart is required. Install the official release with:" >&2
        echo "  brew install cirruslabs/cli/tart" >&2
        exit 1
    fi
}

vm_exists() {
    tart get "$VM_NAME" >/dev/null 2>&1
}

release_run_lock() {
    if [[ "$RUN_LOCK_HELD" == true ]]; then
        rm -f "$RUN_LOCK"
        RUN_LOCK_HELD=false
    fi
    tart_queue_leave
}

# A run from a checkout that predates the queue still takes only this share lock. Wait it out
# rather than failing or touching its guest; shlock itself discards a dead holder's lock.
acquire_share_lock() {
    local reported=false
    mkdir -p "$SHARE_DIR"
    until /usr/bin/shlock -f "$RUN_LOCK" -p "$$"; do
        if [[ "$reported" == false ]]; then
            echo "Another Tart E2E run already owns $SHARE_DIR (PID $(<"$RUN_LOCK")) outside the queue; waiting for it."
            reported=true
        fi
        sleep 2
    done
    RUN_LOCK_HELD=true
}

# The guest writes into the shared results directory, which the next run clears. Move it into
# this run's own directory while the share lock still guarantees it is this run's output.
collect_results() {
    [[ "$RESULTS_COLLECTED" == false && "$RUN_LOCK_HELD" == true ]] || return 0
    RESULTS_COLLECTED=true
    if [[ -d "$SHARE_DIR/results" ]]; then
        mv "$SHARE_DIR/results" "$RUN_DIR/results"
    fi
    if [[ -f "$RUN_DIR/guest.log" ]]; then
        cp "$RUN_DIR/guest.log" "$SHARE_DIR/e2e-latest.log"
    fi
}

artifact_digests() {
    local app e2e guest
    [[ -n "$APP_ARTIFACT" && -f "$SHARE_DIR/$APP_ARTIFACT" ]] || { echo '{}'; return; }
    app="$(shasum -a 256 "$SHARE_DIR/$APP_ARTIFACT" | cut -d' ' -f1)"
    e2e="$(shasum -a 256 "$SHARE_DIR/$E2E_ARTIFACT" | cut -d' ' -f1)"
    guest="$(shasum -a 256 "$SHARE_DIR/$GUEST_ARTIFACT" | cut -d' ' -f1)"
    printf '{"appArchive": "%s", "e2eExecutable": "%s", "guestScript": "%s"}\n' "$app" "$e2e" "$guest"
}

# Runs on every exit, including failures and Ctrl-C, so a report and the evidence always exist.
finish_run() {
    local status=$? reached suite_started=false result cpu
    trap - EXIT INT TERM
    if [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]]; then
        reached="$(run_report_reached)"
        run_report_close_phase "$status"
        collect_results
        grep -q $'^suite\t' "$RUN_DIR/results/guest-phases.tsv" 2>/dev/null && suite_started=true
        result="$(run_report_classify "$status" "$reached" "$suite_started" "$RUN_CANCELED")"
        cpu="{\"buildCpuSeconds\": ${BUILD_CPU_SECONDS:-null}, \"suiteVmCpuSeconds\": ${SUITE_VM_CPU_SECONDS:-null}}"
        run_report_write "$RUN_DIR" "$result" "$SOURCE_IDENTITY" \
            "{\"durationProfile\": \"$DURATION_PROFILE\", \"gallery\": \"$GALLERY_CAPTURE\", \"vm\": \"$VM_NAME\", \"reachedPhase\": \"$reached\"}" \
            "$(artifact_digests)" "$cpu" || echo "Could not write $RUN_DIR/report.json" >&2
        echo
        run_report_summary "$RUN_DIR" 2>/dev/null || echo "Tart E2E run: $result ($RUN_DIR)"
        # Pruning while holding the queue cannot delete another run's live directory.
        if [[ "$RUN_LOCK_HELD" == true ]]; then
            run_report_prune "$RUNS_DIR" "$KEEP_RUNS" "$RUN_DIR"
        fi
    fi
    release_run_lock
    exit "$status"
}

timed_build() {
    local before after
    before="$(run_report_children_cpu_seconds)"
    build_products
    after="$(run_report_children_cpu_seconds)"
    BUILD_CPU_SECONDS="$(awk -v a="$before" -v b="$after" 'BEGIN { printf "%.1f", b - a }')"
}

enter_queue() {
    tart_queue_enter "tart-e2e $(basename "$PROJECT_DIR") $DURATION_PROFILE"
    acquire_share_lock
}

restart_guest() {
    # First-use permission and desktop setup must start with a fresh compositor.
    # A warm guest after the desktop stress scenarios can retain a partial swipe
    # and refuse to open Mission Control despite reporting a settled desktop.
    if guest_is_ready; then
        echo "Restarting the guest before first-use validation..."
        tart stop "$VM_NAME"
    fi
    start_vm
}

run_guest() {
    local guest_ip remote_command ssh_status vm_cpu_before
    echo "Running the full E2E suite inside $VM_NAME (duration profile: $DURATION_PROFILE, gallery: $GALLERY_CAPTURE)..."
    remote_command="$(guest_command)"
    vm_cpu_before="$(run_report_vm_cpu_seconds)"
    set +e
    if guest_ip="$(tart ip "$VM_NAME" --wait 15 2>/dev/null)"; then
        ssh -i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile="$KNOWN_HOSTS" "admin@$guest_ip" "$remote_command" \
            2>&1 | tee "$RUN_DIR/guest.log"
        ssh_status="${PIPESTATUS[0]}"
    else
        # DHCP is not guaranteed in a headless Tart guest. Enter over vsock, then
        # launch through loopback SSH so the input driver keeps the same TCC-responsible
        # identity as the ordinary network path.
        tart exec "$VM_NAME" /bin/bash -c '
            set -e
            umask 077
            key="$HOME/.ssh/id_ed25519_debut_e2e_loopback"
            [[ -f "$key" ]] || ssh-keygen -q -t ed25519 -N "" -C "debut-e2e-loopback" -f "$key"
            grep -qxF "$(<"$key.pub")" "$HOME/.ssh/authorized_keys" || cat "$key.pub" >> "$HOME/.ssh/authorized_keys"
            exec ssh -i "$key" -o BatchMode=yes -o StrictHostKeyChecking=accept-new admin@127.0.0.1 "$1"
        ' _ "$remote_command" 2>&1 | tee "$RUN_DIR/guest.log"
        ssh_status="${PIPESTATUS[0]}"
    fi
    set -e
    SUITE_VM_CPU_SECONDS="$(awk -v a="$vm_cpu_before" -v b="$(run_report_vm_cpu_seconds)" 'BEGIN { printf "%.1f", b - a }')"
    return "$ssh_status"
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

# Builds in this checkout only, so it runs before the queue: a waiting task compiles while it
# waits, and never holds the guest while compiling.
build_products() {
    local build_log
    echo "Building Debut and the E2E executable on the host..."
    # The bundle name belongs to build-app.sh; naming it again here is how a rename last
    # slipped through, staging a path that no longer existed.
    build_log="$(mktemp)"
    "$PROJECT_DIR/scripts/build-app.sh" | tee "$build_log"
    APP_BUNDLE="$(awk '/^Built: /{ sub(/^Built: /, ""); print }' "$build_log")"
    rm -f "$build_log"
    if [[ -z "$APP_BUNDLE" || ! -d "$APP_BUNDLE" ]]; then
        echo "build-app.sh did not report a built app bundle." >&2
        exit 1
    fi
}

# Replaces the previous run's artifacts in the shared directory, so it needs the queue.
space_build() {
    local ARTIFACT_ID
    local old_artifacts=()
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
    /usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$SHARE_DIR/$APP_ARTIFACT"
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

prepare_loopback_ssh() {
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
    if ! vm_exists; then
        echo "Tart VM $VM_NAME does not exist. Run scripts/tart-e2e.sh prepare first." >&2
        exit 1
    fi
    RUN_DIR="$RUNS_DIR/$(date -u +%Y%m%dT%H%M%S)-$$"
    mkdir -p "$RUN_DIR"
    trap finish_run EXIT
    trap 'RUN_CANCELED=true; exit 130' INT TERM
    SOURCE_IDENTITY="$(run_report_source_identity "$PROJECT_DIR")"

    run_report_phase build timed_build
    run_report_phase queue enter_queue
    run_report_phase stage space_build
    run_report_phase boot restart_guest
    run_report_phase provision prepare_loopback_ssh
    local guest_status
    set +e
    run_report_phase guest run_guest
    guest_status=$?
    set -e
    run_report_phase collect collect_results
    return "$guest_status"
}

show_status() {
    tart_queue_status
    if ! vm_exists; then
        echo "Tart VM not prepared: $VM_NAME"
        return
    fi
    tart get "$VM_NAME"
    if guest_is_ready; then
        echo "Guest agent: ready"
    else
        echo "State: stopped"
    fi
}

stop_vm() {
    local holder
    holder="$(tart_queue_holder)"
    if [[ -n "$holder" && "${1:-}" != --force ]]; then
        echo "Not stopping $VM_NAME: a queued run holds it: $holder" >&2
        echo "Wait for it, or pass --force to stop the guest anyway." >&2
        exit 1
    fi
    tart stop "$VM_NAME"
}

# Sourcing defines the functions without running a command, which is how the contract checks
# exactly what crosses the VM boundary.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

case "${1:-}" in
    prepare) require_tart; prepare_vm ;;
    run) shift; parse_run_options "$@"; require_tart; run_e2e ;;
    stop) require_tart; stop_vm "${2:-}" ;;
    status) require_tart; show_status ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
esac
