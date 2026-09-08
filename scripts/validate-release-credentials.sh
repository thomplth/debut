#!/bin/bash
set -euo pipefail

channel="${1:?usage: validate-release-credentials.sh <nightly|stable>}"

case "$channel" in
    nightly|stable) ;;
    *) echo "Unknown release channel: $channel" >&2; exit 1 ;;
esac

required=(
    DEVELOPER_ID_CERTIFICATE_BASE64
    DEVELOPER_ID_CERTIFICATE_PASSWORD
    DEVELOPER_IDENTITY
    APP_STORE_CONNECT_API_KEY_P8
    APP_STORE_CONNECT_API_KEY_ID
    APP_STORE_CONNECT_ISSUER_ID
    SPARKLE_EDDSA_PRIVATE_KEY
    SPARKLE_PUBLIC_ED_KEY
)
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

root="$(cd "$(dirname "$0")/.." && pwd)"
stable_public_key="$(grep -A1 '<key>SUPublicEDKey</key>' "$root/Resources/Info.plist" \
    | sed -nE 's/.*<string>([^<]+)<\/string>.*/\1/p')"
[[ -n "$stable_public_key" ]] || { echo "Could not read the stable Sparkle public key." >&2; exit 1; }
if [[ "$channel" == stable && "$SPARKLE_PUBLIC_ED_KEY" != "$stable_public_key" ]]; then
    echo "Stable environment public key does not match the checked-in stable identity." >&2
    exit 1
fi
if [[ "$channel" == nightly && "$SPARKLE_PUBLIC_ED_KEY" == "$stable_public_key" ]]; then
    echo "Nightly automatic updates must use a distinct Sparkle identity." >&2
    exit 1
fi

echo "$channel release credentials are available."
