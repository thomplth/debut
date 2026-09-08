#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

failures=0

fail() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

research_paths=(
    Sources/DebutGlassLab
    Sources/DebutCore/Views/GlassLabCaptureValidator.swift
    Sources/DebutCore/Views/GlassLabRecipe.swift
    Tests/DebutCoreTests/GlassLabRecipeTests.swift
    docs/KHA-422-liquid-glass-lab.md
    scripts/build-glass-lab.sh
    scripts/tart-glass-lab-guest.sh
    scripts/tart-glass-lab.sh
)

for path in "${research_paths[@]}"; do
    [[ ! -e "$path" ]] || fail "research artifact remains in the product repository: $path"
done

if grep -q 'exclude: \["Screenshots"\]' Package.swift; then
    fail "Package.swift excludes a generated screenshot directory that need not exist"
fi

if grep -q 'appendingPathComponent("Screenshots")' Tests/DebutCoreTests/ScreenshotTests.swift; then
    fail "screenshot tests write generated PNGs into the source tree"
fi

# Contributor-facing files must not require a maintainer's account or machine.
python3 - <<'CHECK' || fail "external contribution boundary"
from pathlib import Path
for name in ('AGENTS.md', 'CONTRIBUTING.md', 'README.md'):
    path = Path(name)
    assert path.is_file(), f"Missing contributor entry point: {name}"
    text = path.read_text()
    for personal in ('KHA-', 'Linear is the source', '/Users/',
                     'single explicit release request', 'single explicit user request',
                     'merge the task branch into `main`'):
        assert personal not in text, f"Personal workflow in {name}: {personal}"
for name in ('Sources/DebutSpaceSwitchLab', 'Sources/SpaceSwitchLabCore',
             'Tests/SpaceSwitchLabTests', 'scripts/build-space-switch-lab.sh',
             'Resources/SpaceSwitchLabInfo.plist', 'docs/html',
             'spec/behaviors.md', 'spec/space-manager.md', 'CLAUDE.md'):
    assert not Path(name).exists(), f"Obsolete or personal artifact: {name}"
assert 'SpaceSwitchLab' not in Path('Package.swift').read_text()
# The demo's offline browser inputs must survive documentation removal.
import re
for page in re.findall(r'\$DESK_DIR/html/([^"\s]+)', Path('scripts/demo-capture-guest.sh').read_text()):
    assert (Path('Tests/Fixtures/Demo/html') / page).is_file(), f"Missing demo page: {page}"
assert '$PROJECT_DIR/Tests/Fixtures/Demo/html' in Path('scripts/demo-capture.sh').read_text()
# Local Markdown links in the contributor entry points must resolve.
for name in ('README.md', 'CONTRIBUTING.md', 'AGENTS.md'):
    for target in re.findall(r'\]\(([^)]+)\)', Path(name).read_text()):
        if '://' not in target and not target.startswith('#'):
            assert Path(target.split('#')[0]).exists(), f"Broken link in {name}: {target}"
CHECK

if grep -q 'Tools/space-probe' Sources/DebutCore/Services/SpaceService.swift; then
    fail "SpaceService points readers to probes that were removed from the repository"
fi

if (( failures > 0 )); then
    exit 1
fi

echo "PASS: repository hygiene contract"
