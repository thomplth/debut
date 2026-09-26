#!/bin/bash
set -euo pipefail

# Plans and runs the verification a change needs.
#
#   scripts/verify.sh plan [--base <ref>] [--release] [--json]
#   scripts/verify.sh check-manifest
#   scripts/verify.sh replay [count]   # plan each of the last commits on main, report-only
#
# The plan is report-only: it says which E2E groups, duration profile, Swift tests and contracts
# a change needs, and why, without running anything or changing any gate.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
    plan) shift; exec python3 "$SCRIPT_DIR/verify/plan.py" "$@" ;;
    check-manifest) exec python3 "$SCRIPT_DIR/verify/plan.py" check-manifest ;;
    replay)
        # Observation mode: how often would real history have been narrowed below full?
        count="${2:-100}"
        changes="$(mktemp)"
        trap 'rm -f "$changes"' EXIT
        full=0; narrowed=0; none=0
        for commit in $(git rev-list --no-merges --max-count="$count" HEAD); do
            git diff-tree --no-commit-id -r --name-status -M "$commit" > "$changes"
            selection="$(python3 "$SCRIPT_DIR/verify/plan.py" --changes "$changes" --json \
                | python3 -c 'import json,sys; d=json.load(sys.stdin); e=d["e2e"]; print(e if e == "full" else (",".join(e) or "none"))')"
            case "$selection" in full) full=$((full + 1)) ;; none) none=$((none + 1)) ;; *) narrowed=$((narrowed + 1)) ;; esac
            printf '%s  %s\n' "$(git log -1 --format='%h %<(60,trunc)%s' "$commit")" "$selection"
        done
        echo "Of the last $count commits: $full full, $narrowed narrowed, $none without a VM."
        ;;
    *)
        sed -n '4,11p' "$0" | sed 's/^# \{0,1\}//' >&2
        exit 2
        ;;
esac
