#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
baseline="${1:?missing baseline DMG}"
candidate="${2:?missing candidate DMG}"
appcast="${3:?missing appcast}"
fixture="${4:?missing fixture directory}"
mkdir -p "$fixture"
cp "$baseline" "$fixture/baseline.dmg"
cp "$candidate" "$fixture/Debut.dmg"
# The feed is not signed. Only its transport URL changes: the archive bytes and
# EdDSA signature are the exact candidate that will be published.
python3 - "$appcast" "$fixture/appcast.xml" <<'PY'
import sys, re
from pathlib import Path
text = Path(sys.argv[1]).read_text()
text, count = re.subn(r'(<enclosure\s+url=")[^"]+("\s)', r'\g<1>http://127.0.0.1:18765/Debut.dmg\2', text)
assert count == 1, 'expected one enclosure URL'
Path(sys.argv[2]).write_text(text)
PY
TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault /usr/bin/swiftc "$root/Tests/Release/UpdateDriver.swift" -o "$fixture/update-driver"
codesign --force -s - "$fixture/update-driver"
cp "$root/scripts/update-e2e-guest.sh" "$fixture/guest.sh"
