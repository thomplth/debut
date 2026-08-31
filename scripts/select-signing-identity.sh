#!/bin/bash
set -euo pipefail

requested_identity="${1:-}"
if [[ -n "$requested_identity" ]]; then
    printf '%s\n' "$requested_identity"
    exit 0
fi

security_bin="${SECURITY_BIN:-security}"
identities="$("$security_bin" find-identity -v -p codesigning 2>/dev/null || true)"

# Stable releases are signed by this Developer ID team. Prefer any current certificate issued to
# that team so local and stable builds satisfy the same designated requirement and retain TCC
# grants when one replaces the other.
identity="$(printf '%s\n' "$identities" \
    | awk '/"Developer ID Application: .* \(G3BV7DB653\)"/ { print $2; exit }')"

if [[ -z "$identity" ]]; then
    identity="$(printf '%s\n' "$identities" \
        | awk '/"Debut Dev"/ { print $2; exit }')"
fi

printf '%s\n' "${identity:--}"
