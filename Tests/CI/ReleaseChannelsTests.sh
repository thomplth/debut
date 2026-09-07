#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
export RELEASE_TEST_ROOT="$root"
python3 - <<'PY'
import os, subprocess, tempfile, pathlib
root = pathlib.Path(os.environ['RELEASE_TEST_ROOT'])
with tempfile.TemporaryDirectory() as d:
    def git(*args): return subprocess.check_output(['git', '-C', d, *args], text=True).strip()
    git('init', '-q'); git('config', 'user.name', 'Tests'); git('config', 'user.email', 'test@example.com')
    def commit(): git('commit', '-q', '--allow-empty', '-m', 'Change')
    def plan(mode, *args):
        result = subprocess.run([str(root/'scripts/release-plan.sh'), mode, *args], cwd=d,
            env={**os.environ, 'RELEASE_DATE':'20260908'}, text=True, capture_output=True)
        assert result.returncode == 0, result.stderr
        return dict(line.split('=', 1) for line in result.stdout.splitlines())
    commit(); git('tag', 'v0.4.0'); commit(); git('tag', 'v0.4.1'); commit(); git('tag', 'v0.4.3')
    p = plan('patch')
    assert p['previous_tag'] == 'v0.4.0', p
    assert p['version'] == '0.4.4', p # Never reuse an old daily tag.
    assert p['channel'] == 'stable' and p['build_version'] == '10000', p
    p = plan('nightly', '--require-changes')
    assert p['version'] == '0.5.0-nightly.20260908', p
    assert p['should_release'] == 'false', p
    commit()
    p = plan('nightly', '--require-changes')
    assert p['channel'] == 'daily' and p['should_release'] == 'true', p
    git('tag', '-a', p['tag'], '-m', 'Debut '+p['tag']+'\n\nDebut-build: 10000')
    p = plan('nightly', '--require-changes')
    assert p['should_release'] == 'false', p
    assert p['version'] == '0.5.0-nightly.20260908.2' and p['build_version'] == '10001', p
    commit(); git('tag', '-a', 'v0.4.4', '-m', 'Debut v0.4.4\n\nDebut-build: 10001')
    p = plan('patch')
    assert p['version'] == '0.4.5' and p['previous_tag'] == 'v0.4.4', p
    p = plan('nightly', '--require-changes')
    assert p['should_release'] == 'false', p # Stable publication also covers today's source.
    git('tag', 'v99.0.0-junk'); git('tag', 'v88.0.0-nightly.20260908')
    assert plan('minor')['version'] == '0.5.0'
    # The full label belongs in the app, but plist versions must stay numeric.
    source = pathlib.Path(d)/'Sources/DebutCore'; source.mkdir(parents=True)
    (source/'DebutCore.swift').write_text('public static let version = "0.0.0-dev"\n')
    resources = pathlib.Path(d)/'Resources'; resources.mkdir()
    import plistlib
    plist = resources/'Info.plist'
    plist.write_bytes(plistlib.dumps({'CFBundleShortVersionString':'0.0.0-dev','CFBundleVersion':'1'}))
    subprocess.run([str(root/'scripts/apply-version.sh'), '0.5.0-nightly.20260908.2', '10002'], cwd=d, check=True)
    info = plistlib.loads(plist.read_bytes())
    assert info['CFBundleShortVersionString'] == '0.5.0' and info['CFBundleVersion'] == '10002', info
    assert '0.5.0-nightly.20260908.2' in (source/'DebutCore.swift').read_text()
print('PASS: release channels, migration, build ordering, and nightly stamping')
PY
