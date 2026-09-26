#!/bin/bash
set -euo pipefail

# Refuses to publish unless the checkout is still exactly the commit the CI and E2E gates tested.
# A release run freezes its version at that commit; later main commits belong to the next release.
#
# Usage: verify-release-commit.sh <sha>

sha="${1:-}"
if [[ -z "$sha" ]]; then
    echo "usage: verify-release-commit.sh <sha>" >&2
    exit 2
fi

head="$(git rev-parse HEAD)"
if [[ "$head" != "$sha" ]]; then
    echo "Checked out $head, but the gates tested $sha." >&2
    exit 1
fi

echo "The release checkout matches the tested commit $sha."
