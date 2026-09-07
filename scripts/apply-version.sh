#!/bin/bash
set -euo pipefail

# Rewrites the two places the app states its own version. Runs against the current directory so
# the release tests can drive it with fixture files.
#
# Usage: apply-version.sh <version> [numeric-build-version]

version="${1:-}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-nightly\.[0-9]{8}(\.[1-9][0-9]*)?)?$ ]]; then
    echo "usage: apply-version.sh <major.minor.patch[-nightly.YYYYMMDD[.N]]> [numeric-build-version]" >&2
    exit 2
fi

short_version="${version%%-*}"
build_version="${2:-$short_version}"
[[ "$build_version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "invalid numeric bundle build" >&2; exit 2; }
if [[ "$version" == *-nightly.* && -z "${2:-}" ]]; then
    echo "nightlies require the build_version from release-plan.sh" >&2
    exit 2
fi

source_file="Sources/DebutCore/DebutCore.swift"
plist="Resources/Info.plist"

for file in "$source_file" "$plist"; do
    [[ -f "$file" ]] || { echo "missing $file" >&2; exit 1; }
done

# Rewriting in place keeps the checked-in formatting; PlistBuddy would reflow the whole file.
set_plist_string() {
    local key="$1"
    local value="$2"
    awk -v key="$key" -v value="$value" '
        $0 ~ "<key>" key "</key>" {
            print
            if ((getline next_line) > 0) {
                sub(/<string>[^<]*<\/string>/, "<string>" value "</string>", next_line)
                print next_line
            }
            next
        }
        { print }
    ' "$plist" > "$plist.tmp"
    mv "$plist.tmp" "$plist"
}

sed -E -i '' "s/(public static let version = \")[^\"]*(\")/\1$version\2/" "$source_file"
set_plist_string CFBundleShortVersionString "$short_version"
# The publish workflow supplies the monotonic build recorded in its annotated tag.
set_plist_string CFBundleVersion "$build_version"

# A rewrite that quietly matched nothing would ship a build reporting the previous version.
verify() {
    local file="$1"
    local pattern="$2"
    local message="$3"
    grep -q -- "$pattern" "$file" || { echo "apply-version: $message" >&2; exit 1; }
}

verify "$source_file" "public static let version = \"$version\"" \
    "could not set the version in $source_file"
grep -A1 "<key>CFBundleShortVersionString</key>" "$plist" | grep -q "<string>$short_version</string>" \
    || { echo "apply-version: could not set CFBundleShortVersionString in $plist" >&2; exit 1; }
grep -A1 "<key>CFBundleVersion</key>" "$plist" | grep -q "<string>$build_version</string>" \
    || { echo "apply-version: could not set CFBundleVersion in $plist" >&2; exit 1; }

echo "Applied version $version"
