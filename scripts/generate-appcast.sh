#!/bin/bash
set -euo pipefail

version="${1:-}"
dmg="${2:-}"
private_key="${3:-}"
output="${4:-}"

if [[ -z "$output" ]]; then
    echo "usage: generate-appcast.sh <version> <dmg> <private-key> <output>" >&2
    exit 2
fi

"$(dirname "$0")/stable-update-eligibility.sh" stable "$version" >/dev/null
[[ -f "$dmg" ]] || { echo "missing update archive: $dmg" >&2; exit 1; }
[[ -f "$private_key" ]] || { echo "missing Sparkle private key: $private_key" >&2; exit 1; }

sign_update="${SPARKLE_SIGN_UPDATE:-.build/artifacts/sparkle/Sparkle/bin/sign_update}"
[[ -x "$sign_update" ]] || { echo "missing Sparkle sign_update tool: $sign_update" >&2; exit 1; }

signature="$($sign_update --ed-key-file "$private_key" "$dmg")"
[[ "$signature" == sparkle:edSignature=*length=* ]] || {
    echo "Sparkle did not return enclosure signing attributes" >&2
    exit 1
}

repository="${GITHUB_REPOSITORY:-thomplth/debut}"
published="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S %z')"
download_url="https://github.com/$repository/releases/download/v$version/Debut.dmg"
release_url="https://github.com/$repository/releases/tag/v$version"

{
    echo '<?xml version="1.0" encoding="utf-8"?>'
    echo '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
    echo '  <channel>'
    echo '    <title>Debut Updates</title>'
    echo "    <link>$release_url</link>"
    echo '    <description>Stable Debut releases</description>'
    echo '    <language>en</language>'
    echo '    <item>'
    echo "      <title>Debut $version</title>"
    echo "      <pubDate>$published</pubDate>"
    echo "      <sparkle:version>$version</sparkle:version>"
    echo "      <sparkle:shortVersionString>$version</sparkle:shortVersionString>"
    echo "      <sparkle:releaseNotesLink>$release_url</sparkle:releaseNotesLink>"
    echo "      <enclosure url=\"$download_url\" $signature type=\"application/octet-stream\"/>"
    echo '    </item>'
    echo '  </channel>'
    echo '</rss>'
} > "$output"

/usr/bin/xmllint --noout "$output"
echo "Generated: $output"
