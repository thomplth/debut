#!/bin/bash
set -euo pipefail

channel="${1:-}"
version="${2:-}"

case "$channel" in
    stable)
        [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
            echo "stable automatic updates require a numeric stable release" >&2
            exit 1
        }
        ;;
    nightly)
        [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-nightly\.[0-9]{8}(\.[1-9][0-9]*)?$ ]] || {
            echo "nightly automatic updates require a nightly release version" >&2
            exit 1
        }
        ;;
    *)
        echo "unknown automatic-update channel: $channel" >&2
        exit 1
        ;;
esac

echo "eligible=true"
