#!/bin/bash
# Export 1024x1024 flat previews of every appearance of smthz.icon with ictool,
# the renderer bundled inside Icon Composer.app (same engine as File > Export).
# Usage (from the repo root): assets/AppIcon/tools/render_previews.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ICTOOL="$DEVELOPER_DIR/../Applications/Icon Composer.app/Contents/Executables/ictool"
ICON="$ROOT/assets/AppIcon/smthz.icon"
OUT="$ROOT/assets/AppIcon/previews"
mkdir -p "$OUT"

for rendition in Default Dark ClearLight ClearDark TintedLight TintedDark Mono; do
  "$ICTOOL" "$ICON" --export-image --output-file "$OUT/smthz-$rendition.png" \
    --platform macOS --rendition "$rendition" --width 1024 --height 1024 --scale 1 >/dev/null
  echo "wrote $OUT/smthz-$rendition.png"
done
