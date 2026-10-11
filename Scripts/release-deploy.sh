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
# Build and sign the replacement BEFORE anything is deleted. The old order —
# `rm -rf /Applications/Anemia.app`, copy, xattr, codesign — left the machine
# with no installed app whenever the copy or the signing failed (iCloud evicting
# a resource mid-copy, detritus codesign refuses, a stale /tmp build), and the
# working previous install was already gone by then.
staged="/Applications/.Anemia.app.staging"
rm -rf "$staged"
cp -R /tmp/Anemia.app "$staged"
# iCloud detritus breaks ad-hoc codesign; scrub before signing.
xattr -cr "$staged" 2>/dev/null || true
codesign --force --deep --sign - "$staged"

pkill -x LoaderApp 2>/dev/null || true
sleep 1
previous="/Applications/.Anemia.app.previous"
rm -rf "$previous"
[[ -d $OUT ]] && mv "$OUT" "$previous"
if mv "$staged" "$OUT"; then
    rm -rf "$previous"
else
    echo "✗ could not put the new build in place — restoring the previous app" >&2
    [[ -d $previous ]] && mv "$previous" "$OUT"
    exit 1
fi

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