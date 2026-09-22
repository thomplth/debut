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

# Personal agent and editor configuration is expected on a contributor's disk; CONTRIBUTING.md
# asks only that it stay untracked. Requiring absence instead fails every checkout that follows
# those instructions, which is what the agent files themselves tell a contributor to set up.
for path in CLAUDE.md AGENTS.override.md .debut-local; do
    if [[ -n "$(git ls-files -- "$path")" ]]; then
        fail "personal configuration is tracked: $path"
    fi
done

# Documentation and package references must remain consistent.
python3 - <<'CHECK' || fail "repository documentation contract"
from pathlib import Path
for name in ('AGENTS.md', 'CONTRIBUTING.md', 'README.md'):
    path = Path(name)
    assert path.is_file(), f"Missing documentation: {name}"
for name in ('Sources/DebutSpaceSwitchLab', 'Sources/SpaceSwitchLabCore',
             'Tests/SpaceSwitchLabTests', 'scripts/build-space-switch-lab.sh',
             'Resources/SpaceSwitchLabInfo.plist', 'docs/html',
             'spec/behaviors.md', 'spec/space-manager.md', 'docs/local-e2e.md',
             'Tests/CI/E2EDocumentationTests.sh'):
    assert not Path(name).exists(), f"Obsolete or personal artifact: {name}"
assert 'SpaceSwitchLab' not in Path('Package.swift').read_text()
# The demo's offline browser inputs must survive documentation removal.
import re
for page in re.findall(r'\$DESK_DIR/html/([^"\s]+)', Path('scripts/demo-capture-guest.sh').read_text()):
    assert (Path('Tests/Fixtures/Demo/html') / page).is_file(), f"Missing demo page: {page}"
assert '$PROJECT_DIR/Tests/Fixtures/Demo/html' in Path('scripts/demo-capture.sh').read_text()
# Local Markdown links must resolve from the document that contains them. Only tracked
# documentation is the repository's to keep consistent; untracked agent notes may link to
# personal files that no clone is expected to have.
import subprocess
tracked = subprocess.run(['git', 'ls-files', '-z', '*.md'],
                         capture_output=True, text=True, check=True).stdout.split('\0')
for path in (Path(name) for name in tracked if name):
    for target in re.findall(r'\]\(([^)]+)\)', path.read_text()):
        if '://' not in target and not target.startswith('#'):
            destination = path.parent / target.split('#')[0]
            assert destination.exists(), f"Broken link in {path}: {target}"
CHECK

if grep -q 'Tools/space-probe' Sources/DebutCore/Services/SpaceService.swift; then
    fail "SpaceService points readers to probes that were removed from the repository"
fi

if (( failures > 0 )); then
    exit 1
fi

echo "PASS: repository hygiene contract"
