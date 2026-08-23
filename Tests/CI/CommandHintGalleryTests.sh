#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
REPORT_DIR="$PROJECT_DIR/docs/design/command-hint-alternatives"
REPORT="$REPORT_DIR/index.html"

[[ -f "$REPORT" ]] || {
    echo "Missing command-hint comparison report: $REPORT" >&2
    exit 1
}

variant_count="$(grep -c 'data-variant=' "$REPORT")"
[[ "$variant_count" -eq 20 ]] || {
    echo "Expected 20 report variants, found $variant_count" >&2
    exit 1
}

unified_indicator_count="$(grep -c 'data-unified-indicator="true"' "$REPORT" || true)"
[[ "$unified_indicator_count" -eq 20 ]] || {
    echo "Expected every variant to include the unified top indicator, found $unified_indicator_count" >&2
    exit 1
}

for number in {1..20}; do
    index="$(printf '%02d' "$number")"
    image="$REPORT_DIR/screenshots/variant-$index.png"
    [[ -f "$image" ]] || {
        echo "Missing VM screenshot: $image" >&2
        exit 1
    }
    width="$(sips -g pixelWidth "$image" | awk '/pixelWidth/{print $2}')"
    height="$(sips -g pixelHeight "$image" | awk '/pixelHeight/{print $2}')"
    [[ "$width" -ge 2000 && "$height" -ge 1200 ]] || {
        echo "Screenshot $index is unexpectedly small: ${width}x${height}" >&2
        exit 1
    }
done

grep -q '<title>Debut Command Hint Alternatives</title>' "$REPORT"
grep -q 'Captured in the headless Tart VM' "$REPORT"
grep -q 'top desktop indicator' "$REPORT"

echo "Command-hint gallery report is complete."
