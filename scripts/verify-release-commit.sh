#!/bin/bash
set -euo pipefail

# Refuses to publish unless the checkout is still exactly the commit the CI and E2E gates tested.
# The gates take minutes and main stays open throughout, so without this a commit that landed in
# that window would be released without any gate having seen it.
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

# FETCH_HEAD rather than origin/main: the publish job checks out a bare SHA, so there is no
# guarantee a remote-tracking branch for main exists or is current.
git fetch --quiet origin main
tip="$(git rev-parse FETCH_HEAD)"
if [[ "$tip" != "$sha" ]]; then
    echo "main advanced to $tip while the gates tested $sha." >&2
    echo "Nothing was published. Re-run the release so the newer commit is gated too." >&2
    exit 1
fi

echo "main still points at the tested commit $sha."
