#!/bin/bash
set -euo pipefail

channel="${1:-}"
version="${2:-}"
dmg="${3:-}"
private_key="${4:-}"
output="${5:-}"
plist="${6:?missing packaged Info.plist}"

if [[ -z "$output" ]]; then
    echo "usage: generate-appcast.sh <nightly|stable> <version> <dmg> <private-key> <output> <packaged Info.plist>" >&2
    exit 2
fi

"$(dirname "$0")/update-eligibility.sh" "$channel" "$version" >/dev/null
[[ -f "$dmg" ]] || { echo "missing update archive: $dmg" >&2; exit 1; }
[[ -f "$private_key" ]] || { echo "missing Sparkle private key: $private_key" >&2; exit 1; }

sign_update="${SPARKLE_SIGN_UPDATE:-.build/artifacts/sparkle/Sparkle/bin/sign_update}"
[[ -x "$sign_update" ]] || { echo "missing Sparkle sign_update tool: $sign_update" >&2; exit 1; }

signature="$($sign_update --ed-key-file "$private_key" "$dmg")"
[[ "$signature" == sparkle:edSignature=*length=* ]] || {
    echo "Sparkle did not return enclosure signing attributes" >&2
    exit 1
}

build_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
minimum_system="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")"
[[ "$build_version" =~ ^[0-9]+(\.[0-9]+){0,2}$ && "$minimum_system" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || {
    echo "invalid packaged version metadata" >&2; exit 1;
}

repository="${GITHUB_REPOSITORY:-thomplth/debut}"
published="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S %z')"
download_url="https://github.com/$repository/releases/download/v$version/Debut.dmg"
release_url="https://github.com/$repository/releases/tag/v$version"
if [[ "$channel" == nightly ]]; then
    feed_title="Debut Nightly Updates"
    feed_description="Nightly Debut releases"
else
    feed_title="Debut Stable Updates"
    feed_description="Stable Debut releases"
fi

{
    echo '<?xml version="1.0" encoding="utf-8"?>'
    echo '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
    echo '  <channel>'
    echo "    <title>$feed_title</title>"
    echo "    <link>$release_url</link>"
    echo "    <description>$feed_description</description>"
    echo '    <language>en</language>'
    echo '    <item>'
    echo "      <title>Debut $version</title>"
    echo "      <pubDate>$published</pubDate>"
    echo "      <sparkle:version>$build_version</sparkle:version>"
    echo "      <sparkle:shortVersionString>$short_version</sparkle:shortVersionString>"
    echo "      <sparkle:minimumSystemVersion>$minimum_system</sparkle:minimumSystemVersion>"
    echo "      <sparkle:releaseNotesLink>$release_url</sparkle:releaseNotesLink>"
    echo "      <enclosure url=\"$download_url\" $signature type=\"application/octet-stream\"/>"
    echo '    </item>'
    echo '  </channel>'
    echo '</rss>'
} > "$output"

/usr/bin/xmllint --noout "$output"
echo "Generated: $output"
