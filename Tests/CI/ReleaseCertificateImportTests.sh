#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."
umask 077
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=ReleaseFixture \
    -keyout "$fixture/key.pem" -out "$fixture/cert.pem" -days 1 >/dev/null 2>&1
CERTIFICATE_PASSWORD=fixture-password openssl pkcs12 -legacy -export \
    -inkey "$fixture/key.pem" -in "$fixture/cert.pem" \
    -out "$fixture/developer-id.p12" -passout env:CERTIFICATE_PASSWORD

# OpenSSL 3's default provider cannot read the RC2-encrypted certificate bag.
if CERTIFICATE_PASSWORD=fixture-password openssl pkcs12 \
    -in "$fixture/developer-id.p12" -out "$fixture/without-legacy.pem" \
    -nodes -passin env:CERTIFICATE_PASSWORD >/dev/null 2>&1; then
    echo "FAIL: fixture no longer exercises legacy PKCS#12 encryption" >&2
    exit 1
fi

import_command="$(sed -n '/^        openssl pkcs12 -in /p' .github/actions/publish-release/action.yml)"
if [[ -z "$import_command" ]]; then
    echo "FAIL: release action has no PKCS#12 conversion command" >&2
    exit 1
fi

CERTIFICATE_PASSWORD=fixture-password \
    certificate="$fixture/developer-id.p12" identity="$fixture/developer-id.pem" \
    bash -e -c "$import_command"
openssl x509 -in "$fixture/developer-id.pem" -noout -subject | grep -q 'CN=ReleaseFixture'
openssl pkey -in "$fixture/developer-id.pem" -noout
[[ "$(stat -f %Lp "$fixture/developer-id.pem")" == 600 ]]

echo "PASS: legacy PKCS#12 certificate conversion"
