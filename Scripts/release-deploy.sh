#!/usr/bin/env bash
#
# One-command release deploy: rebuild the app (release, arm64, outside the
# iCloud-managed tree), replace /Applications/Anemia.app, relaunch it.
#
#   bash Scripts/release-deploy.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="/Applications/Anemia.app"

echo "→ Building release"
# Pin OUT explicitly: an exported OUT in the caller's environment would
# otherwise redirect the build while the copy below stays on /tmp/Anemia.app
# — installing a stale app with no error.
OUT=/tmp/Anemia.app bash "$ROOT/Scripts/build-app.sh"

echo "→ Installing to $OUT"
pkill -x LoaderApp 2>/dev/null || true
sleep 1
rm -rf "$OUT"
cp -R /tmp/Anemia.app "$OUT"
# iCloud detritus breaks ad-hoc codesign; scrub before signing.
xattr -cr "$OUT" 2>/dev/null || true
codesign --force --deep --sign - "$OUT"

echo "→ Launching"
open "$OUT"
# First launches can stall seconds on Gatekeeper verification — a single
# pgrep after a fixed sleep false-fails there. Poll before declaring failure.
started=0
for _ in 1 2 3; do
  sleep 2
  if pgrep -x LoaderApp >/dev/null; then started=1; break; fi
done
[[ "$started" == 1 ]] && echo "RUNNING — release deployed" || { echo "App did not start"; exit 1; }