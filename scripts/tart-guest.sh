#!/bin/bash
# Which macOS release a Debut Tart guest runs.
#
# Sourced by every script that boots a Debut VM. DEBUT_TART_OS selects the release:
#
#   26 (default)  macOS 26 Tahoe        VM debut-e2e-tahoe  share ~/Library/Caches/Debut/TartE2E
#   27            macOS 27 Golden Gate  VM debut-e2e-27     share ~/Library/Caches/Debut/TartE2E-27
#
# Each release keeps its own VM and share directory, so its SSH key, known hosts and run reports
# never mix with another's. Both still wait in the one Tart queue: a second VM competes for the
# same host. DEBUT_TART_VM, DEBUT_TART_SHARE and DEBUT_TART_IMAGE override single values.
#
# Sets TART_GUEST_OS, TART_GUEST_IMAGE, TART_GUEST_VM, TART_GUEST_SHARE and TART_GUEST_UPDATE_VM.
# An unknown release returns 2 before the caller can reach tart.
tart_guest_select() {
    TART_GUEST_OS="${DEBUT_TART_OS:-26}"
    case "$TART_GUEST_OS" in
        26)
            TART_GUEST_IMAGE="ghcr.io/cirruslabs/macos-tahoe-base:latest"
            TART_GUEST_VM="debut-e2e-tahoe"
            TART_GUEST_SHARE="$HOME/Library/Caches/Debut/TartE2E"
            TART_GUEST_UPDATE_VM="debut-update-tahoe"
            ;;
        27)
            TART_GUEST_IMAGE="ghcr.io/cirruslabs/macos-golden-gate-base:latest"
            TART_GUEST_VM="debut-e2e-27"
            TART_GUEST_SHARE="$HOME/Library/Caches/Debut/TartE2E-27"
            TART_GUEST_UPDATE_VM="debut-update-27"
            ;;
        *)
            echo "Unknown DEBUT_TART_OS '$TART_GUEST_OS'. Known releases: 26 (Tahoe, default), 27 (Golden Gate)." >&2
            return 2
            ;;
    esac
    TART_GUEST_IMAGE="${DEBUT_TART_IMAGE:-$TART_GUEST_IMAGE}"
}
