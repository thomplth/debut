#!/bin/bash
set -euo pipefail

# Decides what the next release is, from the tags alone, and prints it as GitHub Actions output
# lines. Runs against the current directory so the release tests can drive it with a throwaway
# tag history.
#
# Usage: release-plan.sh <patch|minor|major> [--require-changes]

bump="${1:-}"
case "$bump" in
    patch|minor|major) ;;
    *)
        echo "usage: release-plan.sh <patch|minor|major> [--require-changes]" >&2
        exit 2
        ;;
esac

require_changes=false
if [[ "${2:-}" == "--require-changes" ]]; then
    require_changes=true
elif [[ -n "${2:-}" ]]; then
    echo "unknown option: $2" >&2
    exit 2
fi

# --sort=-v:refname orders by version, so v0.10.0 beats v0.9.0 and a release never goes backwards.
previous_tag="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1)"

if [[ -z "$previous_tag" ]]; then
    # Nothing has been released yet, so every bump kind starts the series at the baseline.
    version="0.1.0"
    should_release=true
else
    IFS=. read -r major minor patch <<< "${previous_tag#v}"
    case "$bump" in
        patch) patch=$((patch + 1)) ;;
        minor) minor=$((minor + 1)); patch=0 ;;
        major) major=$((major + 1)); minor=0; patch=0 ;;
    esac
    version="$major.$minor.$patch"

    if [[ "$require_changes" == true ]] && [[ -z "$(git rev-list "$previous_tag"..HEAD)" ]]; then
        should_release=false
    else
        should_release=true
    fi
fi

echo "previous_tag=$previous_tag"
echo "version=$version"
echo "tag=v$version"
echo "should_release=$should_release"
