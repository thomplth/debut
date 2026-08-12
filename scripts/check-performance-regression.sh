#!/bin/bash
set -euo pipefail

baseline="${1:?usage: check-performance-regression.sh <budgets.json> <benchmark.json>}"
current="${2:?usage: check-performance-regression.sh <budgets.json> <benchmark.json>}"
failures=0

while IFS=$'\t' read -r operation baseline_p95 absolute_budget regression_percent; do
    current_p95="$(jq -r --arg operation "$operation" '.benchmarks[] | select(.operation == $operation) | .p95Milliseconds' "$current")"
    [[ -n "$current_p95" ]] || { echo "Missing benchmark: $operation" >&2; failures=$((failures + 1)); continue; }
    if awk -v current="$current_p95" -v absolute="$absolute_budget" -v baseline="$baseline_p95" -v percent="$regression_percent" \
        'BEGIN { exit ! (current > absolute && current > baseline * (1 + percent / 100)) }'; then
        echo "$operation regressed: p95=${current_p95}ms, absolute=${absolute_budget}ms, baseline=${baseline_p95}ms (+${regression_percent}%)" >&2
        failures=$((failures + 1))
    else
        echo "$operation passed: p95=${current_p95}ms"
    fi
done < <(jq -r '.benchmarks | to_entries[] | [.key, .value.baselineP95Milliseconds, .value.absoluteBudgetMilliseconds, .value.regressionPercent] | @tsv' "$baseline")

(( failures == 0 ))
