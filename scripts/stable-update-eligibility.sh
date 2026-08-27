#!/bin/bash
set -euo pipefail

channel="${1:-}"
version="${2:-}"

if [[ "$channel" == "daily" ]]; then
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        echo "invalid release version: $version" >&2
        exit 2
    }
    echo "eligible=false"
    exit 0
fi

if [[ "$channel" != "stable" || ! "$version" =~ ^[0-9]+\.[0-9]+\.0$ ]]; then
    echo "stable automatic updates require a manually promoted major/minor .0 release" >&2
    exit 1
fi

echo "eligible=true"
