#!/bin/bash
set -euo pipefail

# Prints the release body: the commit subjects introduced since the previous release.
#
# Usage: release-notes.sh <previous-tag> <new-tag>

previous_tag="${1:-}"
new_tag="${2:-}"

if [[ -z "$new_tag" ]]; then
    echo "usage: release-notes.sh <previous-tag> <new-tag>" >&2
    exit 2
fi

if [[ -n "$previous_tag" ]]; then
    range="$previous_tag..HEAD"
else
    range="HEAD"
fi

echo "## Changes"
echo

# Merge commits restate work their parents already describe, so they would double every entry.
subjects="$(git log --no-merges --format='- %s' "$range")"
if [[ -n "$subjects" ]]; then
    echo "$subjects"
else
    echo "- No commits since $previous_tag."
fi

if [[ -n "${GITHUB_REPOSITORY:-}" && -n "$previous_tag" ]]; then
    server="${GITHUB_SERVER_URL:-https://github.com}"
    echo
    echo "**Full changelog**: $server/$GITHUB_REPOSITORY/compare/$previous_tag...$new_tag"
fi
