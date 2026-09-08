#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
validator="$root/scripts/validate-release-credentials.sh"
if env -u DEVELOPER_ID_CERTIFICATE_BASE64 -u DEVELOPER_ID_CERTIFICATE_PASSWORD -u DEVELOPER_IDENTITY -u APP_STORE_CONNECT_API_KEY_P8 -u APP_STORE_CONNECT_API_KEY_ID -u APP_STORE_CONNECT_ISSUER_ID "$validator" daily >/dev/null 2>&1; then
    echo 'FAIL: daily signing must reject missing credentials' >&2
    exit 1
fi
export DEVELOPER_ID_CERTIFICATE_BASE64=fixture DEVELOPER_ID_CERTIFICATE_PASSWORD=fixture
export DEVELOPER_IDENTITY=fixture APP_STORE_CONNECT_API_KEY_P8=fixture
export APP_STORE_CONNECT_API_KEY_ID=fixture APP_STORE_CONNECT_ISSUER_ID=fixture
unset SPARKLE_EDDSA_PRIVATE_KEY
"$validator" daily
if "$validator" stable >/dev/null 2>&1; then
    echo 'FAIL: stable signing must still require Sparkle key' >&2; exit 1
fi
if SPARKLE_EDDSA_PRIVATE_KEY=forbidden "$validator" daily >/dev/null 2>&1; then
    echo 'FAIL: daily signing must refuse a leaked Sparkle key' >&2; exit 1
fi
python3 - "$root" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
daily = (root/'.github/workflows/release-daily.yml').read_text()
action = (root/'.github/actions/publish-release/action.yml').read_text()
check = (root/'.github/workflows/verify-daily-signing.yml').read_text()
assert 'environment: daily-release' in daily
assert 'secrets: inherit' not in daily and 'SPARKLE_EDDSA_PRIVATE_KEY' not in daily
assert 'needs: [plan, ci, e2e]' in daily
assert 'uses: ./.github/actions/publish-release' in daily
assert "DEBUT_SIGNING_IDENTITY: ${{ env.DEVELOPER_IDENTITY }}" in action
assert "DEBUT_DISTRIBUTION_SIGNING: '1'" in action
assert "if: inputs.channel == 'stable'" not in action[action.index('- name: Import the Developer'):action.index('- name: Tag the tested')]
assert "if: inputs.channel == 'stable'" not in action[action.index('- name: Notarize'):action.index('- name: Sign and generate')]
assert "if: inputs.dry-run != 'true'" in action[action.index('- name: Push the tag'):]
assert 'contents: read' in check and 'contents: write' not in check
assert 'dry-run: true' in check and 'environment: daily-release' in check
assert 'SPARKLE_EDDSA_PRIVATE_KEY' not in check
assert 'Ad-hoc' not in action and 'ad-hoc' not in action
print('PASS: daily signing, Sparkle isolation, and non-publishing verification')
PY
