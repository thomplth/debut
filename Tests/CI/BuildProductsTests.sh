#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

failures=0
fail() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

build="scripts/build-app.sh"

# Without --plan support the script would run a real release build, so check before invoking it.
if ! grep -q -- '--plan' "$build"; then
    echo "FAIL: $build has no --plan mode; refusing to run a real build from a contract test" >&2
    exit 1
fi

plan_for() {
    DEBUT_BUILD_PRODUCTS="${1:-}" "$build" --plan 2>&1
}

# The app bundle needs only Debut; compiling the demo, benchmark and fixture products for it
# was pure overhead on every local E2E retry.
default_plan="$(DEBUT_BUILD_PRODUCTS= "$build" --plan 2>&1)" \
    || fail "build-app.sh --plan failed: $default_plan"
grep -q -- '--product Debut$' <<< "$default_plan" || fail "the default plan must build the Debut product: $default_plan"
for unrelated in DebutE2E DebutDemo DebutBenchmarks DebutPerformanceFixture; do
    grep -q -- "--product $unrelated" <<< "$default_plan" \
        && fail "the default plan must not build $unrelated"
done
grep -Eq 'swift build -c release --arch arm64$' <<< "$default_plan" \
    && fail "the plan must not build every product"

e2e_plan="$(plan_for "Debut DebutE2E")"
grep -q -- '--product Debut$' <<< "$e2e_plan" || fail "an E2E plan must still build Debut"
grep -q -- '--product DebutE2E$' <<< "$e2e_plan" || fail "an E2E plan must build DebutE2E"
grep -q -- '--product DebutDemo' <<< "$e2e_plan" && fail "an E2E plan must not build the demo"

set +e
bad_output="$(plan_for "Debut NoSuchProduct")"
bad_status=$?
set -e
(( bad_status == 2 )) || fail "an unknown product must be rejected before building (exit $bad_status): $bad_output"

# --plan must not build, assemble or sign anything.
grep -Eq 'Assembling|Code signing|Built:' <<< "$default_plan" && fail "--plan must stop before building"

# Every caller asks for exactly the products it stages.
expect_products() {
    local script="$1" expected="$2"
    grep -Eq "DEBUT_BUILD_PRODUCTS=\"$expected\"" "$script" \
        || fail "$script must request exactly: $expected"
}
expect_products scripts/tart-e2e.sh "Debut DebutE2E"
expect_products scripts/ci-e2e.sh "Debut DebutE2E"
expect_products scripts/demo-capture.sh "Debut DebutE2E"
for app_only in scripts/rebuild.sh scripts/package-dmg.sh scripts/tart-performance.sh; do
    grep -q 'DEBUT_BUILD_PRODUCTS' "$app_only" && fail "$app_only only needs the app"
done

# Products each caller stages come from the build it asked for, not from a stale earlier one.
grep -q 'DebutE2E' scripts/build-app.sh || fail "build-app.sh must know the DebutE2E product"
grep -q 'Built product:' scripts/build-app.sh || fail "build-app.sh must report every built product path"

if (( failures > 0 )); then
    exit 1
fi
echo "PASS: build products contract"
