#!/usr/bin/env bash
#
# Build a distributable Anemia.dmg from the release app bundle.
#   bash Scripts/build-dmg.sh
# Overridables: OUT (dmg path, default /tmp/Anemia.dmg), VOL (volume name).
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${APP:-/tmp/Anemia.app}"
OUT="${OUT:-/tmp/Anemia.dmg}"
VOL="${VOL:-Anemia}"

# Assemble (and rebuild) the app bundle first.
OUT="$APP" bash "$ROOT/Scripts/build-app.sh"
[[ -d "$APP" ]] || { echo "No app bundle at $APP"; exit 1; }

# Staging folder: the app plus a /Applications symlink, so the volume is the
# classic drag-to-install layout. Everything happens outside the iCloud tree
# so the DMG never inherits the extended attributes codesign rejects.
STAGE="$(mktemp -d /tmp/anemia-dmg.XXXXXX)"
DMG_DIR="$(mktemp -d /tmp/anemia-dmg-out.XXXXXX)"
trap 'rm -rf "$STAGE" "$DMG_DIR"' EXIT
cp -R "$APP" "$STAGE/Anemia.app"
ln -s /Applications "$STAGE/Applications"

echo "→ Creating $OUT"
rm -f "$OUT"
# Compressed, zlib-9 image straight from the staging folder.
hdiutil create -srcfolder "$STAGE" -volname "$VOL" \
    -format UDZO -imagekey zlib-level=9 -o "$OUT" -quiet

echo "→ Verifying"
hdiutil verify "$OUT" -quiet
SIZE="$(du -h "$OUT" | cut -f1)"
echo "Done: $OUT ($SIZE)"
echo "Install: open \"$OUT\"  → drag Anemia to Applications"