#!/usr/bin/env bash
# Regenerate Resources/AppIcon.icns from Resources/icon-source.png.
#
# macOS .icns is a multi-resolution bundle. We build the standard
# 10-slot iconset (16/32/128/256/512 in 1x + 2x) with `sips` and pack
# it with `iconutil`. The source PNG should be square and at least
# 1024×1024.
#
# Usage:  ./scripts/make-icon.sh
#         ./scripts/make-icon.sh path/to/other-source.png
#
# This is a one-shot setup step, not part of every build. Re-run it
# only when the icon source changes; the committed AppIcon.icns is
# what scripts/make-app.sh embeds in the app bundle.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SRC="${1:-Resources/icon-source.png}"
OUT="Resources/AppIcon.icns"

[ -f "$SRC" ] || { echo "source PNG not found: $SRC" >&2; exit 1; }
command -v sips     >/dev/null || { echo "sips not in PATH"    >&2; exit 1; }
command -v iconutil >/dev/null || { echo "iconutil not in PATH" >&2; exit 1; }

STAGE="$(mktemp -d -t dht-icon.XXXXXX)"
ISET="${STAGE}/AppIcon.iconset"
mkdir -p "$ISET"
trap 'rm -rf "$STAGE"' EXIT

# Pairs are (filename, pixel size). macOS resolves the right slot at
# render time based on the surface resolution.
PAIRS=(
  "icon_16x16.png:16"
  "icon_16x16@2x.png:32"
  "icon_32x32.png:32"
  "icon_32x32@2x.png:64"
  "icon_128x128.png:128"
  "icon_128x128@2x.png:256"
  "icon_256x256.png:256"
  "icon_256x256@2x.png:512"
  "icon_512x512.png:512"
  "icon_512x512@2x.png:1024"
)

for entry in "${PAIRS[@]}"; do
  name="${entry%%:*}"
  size="${entry##*:}"
  sips -s format png -z "$size" "$size" "$SRC" --out "$ISET/$name" >/dev/null
done

iconutil -c icns "$ISET" -o "$OUT"
echo "wrote $OUT ($(stat -f%z "$OUT") bytes from $SRC)"
