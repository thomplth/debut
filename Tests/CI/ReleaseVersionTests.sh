#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
plan="$repo_root/scripts/release-plan.sh"
notes="$repo_root/scripts/release-notes.sh"
apply="$repo_root/scripts/apply-version.sh"
verify="$repo_root/scripts/verify-release-commit.sh"
failures=0

fail() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

expect_equal() {
    local actual="$1"
    local expected="$2"
    local message="$3"
    if [[ "$actual" != "$expected" ]]; then
        fail "$message (expected '$expected', got '$actual')"
    fi
}

# Each case runs against a throwaway repo so tag history is controlled rather than inherited.
make_repo() {
    local dir
    dir="$(mktemp -d)"
    git -C "$dir" init --quiet
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Release Tests"
    git -C "$dir" commit --quiet --allow-empty -m "Initial commit"
    echo "$dir"
}

field() {
    local output="$1"
    local key="$2"
    grep "^$key=" <<< "$output" | cut -d= -f2-
}

for script in "$plan" "$notes" "$apply" "$verify"; do
    [[ -x "$script" ]] || fail "missing executable $script"
done

if [[ -x "$plan" ]]; then
    # A repo with no release tags restarts the series at the baseline instead of bumping.
    repo="$(make_repo)"
    output="$(cd "$repo" && "$plan" patch)"
    expect_equal "$(field "$output" version)" "0.1.0" "an untagged repo must plan the 0.1.0 baseline"
    expect_equal "$(field "$output" should_release)" "true" "an untagged repo must be releasable"
    expect_equal "$(field "$output" previous_tag)" "" "an untagged repo must report no previous tag"
    rm -rf "$repo"

    repo="$(make_repo)"
    git -C "$repo" tag v0.1.0
    git -C "$repo" commit --quiet --allow-empty -m "KHA-1: Add a thing"
    output="$(cd "$repo" && "$plan" patch)"
    expect_equal "$(field "$output" version)" "0.1.1" "patch bumps must increment the third number"
    expect_equal "$(field "$output" previous_tag)" "v0.1.0" "the plan must report the tag it bumped from"
    rm -rf "$repo"

    # The daily job must not cut an identical release when main has not moved.
    repo="$(make_repo)"
    git -C "$repo" tag v0.1.0
    output="$(cd "$repo" && "$plan" patch --require-changes)"
    expect_equal "$(field "$output" should_release)" "false" \
        "a tagged repo with no new commits must skip the release"
    rm -rf "$repo"

    repo="$(make_repo)"
    git -C "$repo" tag v0.1.0
    git -C "$repo" commit --quiet --allow-empty -m "KHA-2: Change something"
    output="$(cd "$repo" && "$plan" patch --require-changes)"
    expect_equal "$(field "$output" should_release)" "true" \
        "a tagged repo with new commits must release"
    rm -rf "$repo"

    # A human-triggered release goes out even when the tree is unchanged.
    repo="$(make_repo)"
    git -C "$repo" tag v0.1.0
    output="$(cd "$repo" && "$plan" minor)"
    expect_equal "$(field "$output" should_release)" "true" \
        "an unchanged repo must still release without --require-changes"
    expect_equal "$(field "$output" version)" "0.2.0" "minor bumps must reset the patch number"
    rm -rf "$repo"

    repo="$(make_repo)"
    git -C "$repo" tag v0.2.3
    output="$(cd "$repo" && "$plan" major)"
    expect_equal "$(field "$output" version)" "1.0.0" "major bumps must reset the minor and patch numbers"
    rm -rf "$repo"

    # Lexical tag ordering would pick v0.9.0 over v0.10.0 and silently release backwards.
    repo="$(make_repo)"
    git -C "$repo" tag v0.9.0
    git -C "$repo" commit --quiet --allow-empty -m "KHA-3: Later work"
    git -C "$repo" tag v0.10.0
    git -C "$repo" commit --quiet --allow-empty -m "KHA-4: Newer work"
    output="$(cd "$repo" && "$plan" patch)"
    expect_equal "$(field "$output" version)" "0.10.1" "tags must be ordered by version, not lexically"
    rm -rf "$repo"

    # Tags that are not releases must never be mistaken for the previous version.
    repo="$(make_repo)"
    git -C "$repo" tag v0.1.0
    git -C "$repo" tag nightly-latest
    output="$(cd "$repo" && "$plan" patch)"
    expect_equal "$(field "$output" previous_tag)" "v0.1.0" "non-version tags must be ignored"
    rm -rf "$repo"

    repo="$(make_repo)"
    if (cd "$repo" && "$plan" sideways >/dev/null 2>&1); then
        fail "an unknown bump kind must be rejected"
    fi
    rm -rf "$repo"
fi

if [[ -x "$notes" ]]; then
    repo="$(make_repo)"
    git -C "$repo" commit --quiet --allow-empty -m "KHA-5: Released already"
    git -C "$repo" tag v0.1.0
    git -C "$repo" commit --quiet --allow-empty -m "KHA-6: First new change"
    git -C "$repo" commit --quiet --allow-empty -m "KHA-7: Second new change"
    git -C "$repo" commit --quiet --allow-empty -m "Merge branch 'feature'" --no-verify
    output="$(cd "$repo" && "$notes" v0.1.0 v0.1.1)"
    grep -q -- "- KHA-6: First new change" <<< "$output" \
        || fail "release notes must list commit subjects since the previous tag"
    grep -q -- "- KHA-7: Second new change" <<< "$output" \
        || fail "release notes must list every commit since the previous tag"
    if grep -q -- "KHA-5" <<< "$output"; then
        fail "release notes must not repeat commits from the previous release"
    fi
    rm -rf "$repo"

    # The very first release has no predecessor, so the range has to fall back to the whole history.
    repo="$(make_repo)"
    git -C "$repo" commit --quiet --allow-empty -m "KHA-8: Only change"
    output="$(cd "$repo" && "$notes" "" v0.1.0)"
    grep -q -- "- KHA-8: Only change" <<< "$output" \
        || fail "release notes must cover all history when there is no previous tag"
    rm -rf "$repo"

    repo="$(make_repo)"
    git -C "$repo" tag v0.1.0
    output="$(cd "$repo" && GITHUB_REPOSITORY=thomplth/debut "$notes" v0.1.0 v0.1.1)"
    grep -q "compare/v0.1.0\.\.\.v0.1.1" <<< "$output" \
        || fail "release notes must link the full changelog comparison when the repo is known"
    rm -rf "$repo"
fi

if [[ -x "$apply" ]]; then
    repo="$(mktemp -d)"
    mkdir -p "$repo/Sources/DebutCore" "$repo/Resources"
    cat > "$repo/Sources/DebutCore/DebutCore.swift" <<'SWIFT'
public enum DebutCore {
    public static let version = "0.1.0"
}
SWIFT
    cat > "$repo/Resources/Info.plist" <<'PLIST'
<plist version="1.0">
<dict>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
PLIST
    (cd "$repo" && "$apply" 1.2.3)
    grep -q 'public static let version = "1.2.3"' "$repo/Sources/DebutCore/DebutCore.swift" \
        || fail "apply-version must update the version the app reports"
    grep -A1 "CFBundleShortVersionString" "$repo/Resources/Info.plist" | grep -q "<string>1.2.3</string>" \
        || fail "apply-version must update the bundle's short version string"
    grep -A1 "<key>CFBundleVersion</key>" "$repo/Resources/Info.plist" | grep -q "<string>1.2.3</string>" \
        || fail "apply-version must keep the bundle version monotonic with the release"
    rm -rf "$repo"

    # A silent no-op would ship a release whose app reports the previous version.
    repo="$(mktemp -d)"
    mkdir -p "$repo/Sources/DebutCore" "$repo/Resources"
    echo "public enum DebutCore {}" > "$repo/Sources/DebutCore/DebutCore.swift"
    echo "<plist></plist>" > "$repo/Resources/Info.plist"
    if (cd "$repo" && "$apply" 1.2.3 >/dev/null 2>&1); then
        fail "apply-version must fail when it cannot find the version to rewrite"
    fi
    rm -rf "$repo"
fi

if [[ -x "$verify" ]]; then
    # An "origin" plus a checkout of one commit from it reproduces what the publish job sees: a
    # detached HEAD at the commit the gates tested, and a main branch that stayed open meanwhile.
    make_origin_and_clone() {
        local origin clone
        origin="$(mktemp -d)/origin.git"
        git init --quiet --bare --initial-branch=main "$origin"
        clone="$(mktemp -d)"
        git clone --quiet "$origin" "$clone" 2>/dev/null
        git -C "$clone" config user.email "test@example.com"
        git -C "$clone" config user.name "Release Tests"
        git -C "$clone" commit --quiet --allow-empty -m "Initial commit"
        git -C "$clone" push --quiet origin main 2>/dev/null
        echo "$clone"
    }

    clone="$(make_origin_and_clone)"
    sha="$(git -C "$clone" rev-parse HEAD)"
    git -C "$clone" checkout --quiet --detach "$sha"
    (cd "$clone" && "$verify" "$sha" >/dev/null 2>&1) \
        || fail "verify-release-commit must accept the commit main still points at"

    # The failure that actually happened: main moved during the gate window, so the tested commit
    # is no longer what a release would ship.
    worker="$(mktemp -d)"
    git clone --quiet "$(git -C "$clone" remote get-url origin)" "$worker" 2>/dev/null
    git -C "$worker" config user.email "test@example.com"
    git -C "$worker" config user.name "Release Tests"
    git -C "$worker" commit --quiet --allow-empty -m "Landed during the gate window"
    git -C "$worker" push --quiet origin main 2>/dev/null
    if (cd "$clone" && "$verify" "$sha" >/dev/null 2>&1); then
        fail "verify-release-commit must refuse once main has advanced past the tested commit"
    fi
    rm -rf "$worker"

    # A checkout that silently landed somewhere else must not be published either.
    clone2="$(make_origin_and_clone)"
    other="$(git -C "$clone2" rev-parse HEAD)"
    if (cd "$clone2" && "$verify" "${other//[0-9a-f]/a}" >/dev/null 2>&1); then
        fail "verify-release-commit must refuse when HEAD is not the commit it was told to release"
    fi

    # A refusal that says nothing leaves whoever re-runs the release guessing.
    output="$(cd "$clone" && "$verify" "$sha" 2>&1 || true)"
    grep -q "$sha" <<< "$output" \
        || fail "verify-release-commit must name the tested commit when it refuses"
    rm -rf "$clone" "$clone2"
fi

if (( failures > 0 )); then
    exit 1
fi

echo "PASS: release version contract"
