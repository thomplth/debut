#!/bin/bash
# The one list of host settings Debut's checks depend on, and a record of what a host had.
#
#   host-profile.sh fingerprint [--out FILE]   print this host's settings, and save them as JSON
#   host-profile.sh apply [--out FILE]         pin the profile, then fingerprint the result
#
# Hosted runners, the Tart guest and a developer's Mac disagree by default. Runners boot with
# Reduce Motion on, which turned a 0.36s spring into a 0.12s fade under an E2E check in August and
# under a unit test in KHA-815; both passed locally and failed on CI. Every disposable host applies
# this one profile, and every run records the fingerprint, so the next difference is read out of a
# log instead of being rediscovered. Tests/CI/HostEnvironmentTests.sh holds the hosts to it.
#
# apply rewrites the current user's defaults, so it refuses to run outside a disposable host.
# Runs on the guest too, where python3 may be only a Command Line Tools stub: bash and macOS
# tools only. macOS ships bash 3.2.
set -euo pipefail

usage() {
    echo "usage: $0 fingerprint|apply [--out FILE]" >&2
    exit 2
}

command="${1:-}"
shift || true
out=""
while (( $# > 0 )); do
    case "$1" in
        --out) out="${2:?--out needs a file}"; shift 2 ;;
        *) usage ;;
    esac
done

read_default() {
    local value
    value="$(defaults read "$1" "$2" 2>/dev/null)" || value=unset
    printf '%s' "$value"
}

# One line per display: its resolution and what the UI looks like at, e.g. "2560 x 1600 Retina".
displays() {
    system_profiler SPDisplaysDataType 2>/dev/null \
        | awk -F': ' '/Resolution:/ { sub(/^ +/, "", $2); printf "%s%s", sep, $2; sep = "; " }'
}

xcode_version() {
    local version
    version="$(xcodebuild -version 2>/dev/null | head -1)" || version=""
    printf '%s' "${version:-none}"
}

fingerprint() {
    local keys=(reduceMotion reduceTransparency increaseContrast differentiateWithoutColor
        appearance windowAnimations locale macOS xcode hardware virtualized displays)
    local values=(
        "$(read_default com.apple.universalaccess reduceMotion)"
        "$(read_default com.apple.universalaccess reduceTransparency)"
        "$(read_default com.apple.universalaccess increaseContrast)"
        "$(read_default com.apple.universalaccess differentiateWithoutColor)"
        "$(read_default -g AppleInterfaceStyle | sed 's/^unset$/Light/')"
        "$(read_default -g NSAutomaticWindowAnimationsEnabled)"
        "$(read_default -g AppleLocale)"
        "$(sw_vers -productVersion) ($(sw_vers -buildVersion))"
        "$(xcode_version)"
        "$(sysctl -n hw.model 2>/dev/null || echo unknown)"
        "$(sysctl -n kern.hv_vmm_present 2>/dev/null || echo unknown)"
        "$(displays)"
    )
    local i json="{" sep="" value
    for i in "${!keys[@]}"; do
        value="${values[$i]//$'\n'/ }"
        echo "host-profile: ${keys[$i]}=$value"
        value="${value//\\/\\\\}"
        json+="$sep\"${keys[$i]}\": \"${value//\"/\\\"}\""
        sep=", "
    done
    json+="}"
    if [[ -n "$out" ]]; then
        printf '%s\n' "$json" > "$out"
    fi
}

apply() {
    if [[ "${GITHUB_ACTIONS:-}" != true && "${DEBUT_HOST_PROFILE_DISPOSABLE:-}" != 1 ]]; then
        echo "host-profile.sh apply rewrites user defaults and only runs on a disposable host" \
            "(GitHub Actions, or DEBUT_HOST_PROFILE_DISPOSABLE=1 in the Tart guest)." >&2
        exit 1
    fi
    echo "host-profile: before pinning"
    out="" fingerprint
    # The macOS defaults, which is what a developer's Mac and a fresh Tart guest already have.
    # Motion checks sample the 0.36s spring; the 0.12s fade branch is covered by unit tests.
    defaults write com.apple.universalaccess reduceMotion -bool false
    defaults write com.apple.universalaccess reduceTransparency -bool false
    defaults write com.apple.universalaccess increaseContrast -bool false
    defaults write com.apple.universalaccess differentiateWithoutColor -bool false
    defaults delete -g AppleInterfaceStyle 2>/dev/null || true
    defaults write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool true
    echo "host-profile: after pinning"
    fingerprint
}

case "$command" in
    fingerprint) fingerprint ;;
    apply) apply ;;
    *) usage ;;
esac
