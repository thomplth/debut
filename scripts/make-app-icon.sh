#!/bin/bash
set -euo pipefail

# Regenerates Resources/AppIcon.icns from Resources/AppIcon.svg.
#
# The .icns is committed rather than built. GitHub-hosted runners have no librsvg and no
# workflow installs it, so rasterizing during build-app.sh would fail every CI run. Run this
# by hand whenever the SVG changes, and commit the result alongside it.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SVG="$PROJECT_DIR/Resources/AppIcon.svg"
OUT="$PROJECT_DIR/Resources/AppIcon.icns"

command -v rsvg-convert >/dev/null || { echo "rsvg-convert missing: brew install librsvg" >&2; exit 1; }
command -v magick >/dev/null || { echo "magick missing: brew install imagemagick" >&2; exit 1; }
[[ -f "$SVG" ]] || { echo "missing $SVG" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# macOS insets icon artwork: a 1024 canvas carries an 824 body, and the silhouette is a
# continuous-curvature rounded rect rather than the circular arc the source SVG draws. Drop the
# SVG's own clip so the mask below is the only thing shaping the corners. A silent no-op here
# would double-round the corners, so the substitution has to be checked.
sed -E 's/ clip-path="url\(#clip[^"]*\)"//g' "$SVG" > "$WORK/unclipped.svg"
if cmp -s "$SVG" "$WORK/unclipped.svg"; then
    echo "make-app-icon: found no clip-path to strip in $SVG; corners would be rounded twice" >&2
    exit 1
fi

cat > "$WORK/mask.swift" <<'SWIFT'
import AppKit
import SwiftUI

let size = Double(CommandLine.arguments[1])!
let out = CommandLine.arguments[2]
let view = RoundedRectangle(cornerRadius: size * (185.4 / 824.0), style: .continuous)
    .fill(.black)
    .frame(width: size, height: size)
MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1.0
    guard let cg = renderer.cgImage else { fatalError("render failed") }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png failed") }
    try! data.write(to: URL(fileURLWithPath: out))
}
SWIFT

TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault /usr/bin/swiftc -O "$WORK/mask.swift" -o "$WORK/mask"
"$WORK/mask" 824 "$WORK/mask.png"

rsvg-convert -w 824 -h 824 "$WORK/unclipped.svg" -o "$WORK/body.png"
# The mask is a black shape on transparency, so its alpha is the coverage. Compositing the
# colour channels instead would mask everything away.
magick "$WORK/body.png" \( "$WORK/mask.png" -alpha extract \) \
    -compose CopyOpacity -composite "$WORK/masked.png"
magick -size 1024x1024 xc:none "$WORK/masked.png" -geometry +100+100 -composite "$WORK/master.png"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
emit() { magick "$WORK/master.png" -filter Lanczos -resize "${2}x${2}" "$ICONSET/$1"; }
emit icon_16x16.png 16
emit icon_16x16@2x.png 32
emit icon_32x32.png 32
emit icon_32x32@2x.png 64
emit icon_128x128.png 128
emit icon_128x128@2x.png 256
emit icon_256x256.png 256
emit icon_256x256@2x.png 512
emit icon_512x512.png 512
emit icon_512x512@2x.png 1024

iconutil -c icns "$ICONSET" -o "$OUT"
echo "Wrote $OUT"
