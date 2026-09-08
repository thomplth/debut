#!/bin/bash
set -euo pipefail

channel="${1:?usage: validate-release-credentials.sh <daily|stable>}"

case "$channel" in
    daily|stable) ;;
    *) echo "Unknown release channel: $channel" >&2; exit 1 ;;
esac

if [[ "$channel" == daily && -n "${SPARKLE_EDDSA_PRIVATE_KEY:-}" ]]; then
    echo "Daily signing must not receive the Sparkle private key." >&2
    exit 1
fi

required=(
    DEVELOPER_ID_CERTIFICATE_BASE64
    DEVELOPER_ID_CERTIFICATE_PASSWORD
    DEVELOPER_IDENTITY
    APP_STORE_CONNECT_API_KEY_P8
    APP_STORE_CONNECT_API_KEY_ID
    APP_STORE_CONNECT_ISSUER_ID
)
if [[ "$channel" == stable ]]; then required+=(SPARKLE_EDDSA_PRIVATE_KEY); fi
missing=()

for name in "${required[@]}"; do
    if [[ -z "${!name:-}" ]]; then
        missing+=("$name")
    fi
done

if (( ${#missing[@]} > 0 )); then
    echo "$channel release credentials are unavailable:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    exit 1
fi

echo "$channel release credentials are available."
