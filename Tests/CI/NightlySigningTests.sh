#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
validator="$root/scripts/validate-release-credentials.sh"
if env -u DEVELOPER_ID_CERTIFICATE_BASE64 -u DEVELOPER_ID_CERTIFICATE_PASSWORD -u DEVELOPER_IDENTITY -u APP_STORE_CONNECT_API_KEY_P8 -u APP_STORE_CONNECT_API_KEY_ID -u APP_STORE_CONNECT_ISSUER_ID "$validator" nightly >/dev/null 2>&1; then
    echo 'FAIL: nightly signing must reject missing credentials' >&2
    exit 1
fi
export DEVELOPER_ID_CERTIFICATE_BASE64=fixture DEVELOPER_ID_CERTIFICATE_PASSWORD=fixture
export DEVELOPER_IDENTITY=fixture APP_STORE_CONNECT_API_KEY_P8=fixture
export APP_STORE_CONNECT_API_KEY_ID=fixture APP_STORE_CONNECT_ISSUER_ID=fixture
unset SPARKLE_EDDSA_PRIVATE_KEY
"$validator" nightly
if "$validator" stable >/dev/null 2>&1; then
    echo 'FAIL: stable signing must still require Sparkle key' >&2; exit 1
fi
if SPARKLE_EDDSA_PRIVATE_KEY=forbidden "$validator" nightly >/dev/null 2>&1; then
    echo 'FAIL: nightly signing must refuse a leaked Sparkle key' >&2; exit 1
fi
python3 - "$root" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
nightly = (root/'.github/workflows/release-nightly.yml').read_text()
action = (root/'.github/actions/publish-release/action.yml').read_text()
check = (root/'.github/workflows/verify-nightly-signing.yml').read_text()
assert 'environment: nightly-release' in nightly
assert 'secrets: inherit' not in nightly and 'SPARKLE_EDDSA_PRIVATE_KEY' not in nightly
assert 'needs: [plan, ci, e2e]' in nightly
assert 'uses: ./.github/actions/publish-release' in nightly
assert "DEBUT_SIGNING_IDENTITY: ${{ env.DEVELOPER_IDENTITY }}" in action
assert "DEBUT_DISTRIBUTION_SIGNING: '1'" in action
assert "if: inputs.channel == 'stable'" not in action[action.index('- name: Import the Developer'):action.index('- name: Tag the tested')]
assert "if: inputs.channel == 'stable'" not in action[action.index('- name: Notarize'):action.index('- name: Sign and generate')]
assert "if: inputs.dry-run != 'true'" in action[action.index('- name: Push the tag'):]
assert 'contents: read' in check and 'contents: write' not in check
assert 'dry-run: true' in check and 'environment: nightly-release' in check
assert 'SPARKLE_EDDSA_PRIVATE_KEY' not in check
assert 'Ad-hoc' not in action and 'ad-hoc' not in action
print('PASS: nightly signing, Sparkle isolation, and non-publishing verification')
PY
