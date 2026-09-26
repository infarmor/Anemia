#!/usr/bin/env bash
#
# Assemble Anemia.app from the SwiftPM build products for local running.
# Builds the bundle OUTSIDE the iCloud-managed Documents tree so ad-hoc
# codesign doesn't choke on extended-attribute detritus.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Build outside the iCloud-managed Documents tree (see README) but in a
# stable, machine-local scratch dir — never a previous session's temp path.
SCRATCH="${SCRATCH:-/tmp/loader-build}"
# Optimized for Apple Silicon: release build (-O, whole-module), arm64 native.
CONFIG="${CONFIG:-release}"
OUT="${OUT:-/tmp/Anemia.app}"

source "$ROOT/Scripts/toolchain-env.sh"

echo "→ swift build -c $CONFIG (arm64)"
# Apple Silicon release profile:
#  - native arm64 only (no Rosetta slice, smaller/faster dispatch)
#  - cross-module optimization: WPM inlining across LoaderCore/LoaderShared
#    into the app target, where the hot paths (parser, config builder,
#    latency probe) live in a different module than their callers.
swift build -c "$CONFIG" --arch arm64 --scratch-path "$SCRATCH" \
    -Xswiftc -cross-module-optimization
BIN="$SCRATCH/$CONFIG/LoaderApp"
[[ -x "$BIN" ]] || { echo "Build produced no LoaderApp at $BIN"; exit 1; }

echo "→ Assembling $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

cp "$BIN" "$OUT/Contents/MacOS/LoaderApp"
cp "$ROOT/Packaging/LoaderApp-Info.plist" "$OUT/Contents/Info.plist"
# App icon.
[[ -f "$ROOT/Sources/LoaderApp/Resources/AnemiaAppIcon.icns" ]] && \
    cp "$ROOT/Sources/LoaderApp/Resources/AnemiaAppIcon.icns" "$OUT/Contents/Resources/"
# SwiftPM resource bundle (holds AnemiaLogo.png for Bundle.module).
for loc in "$SCRATCH/$CONFIG/Loader_LoaderApp.bundle" "$SCRATCH/$CONFIG/LoaderApp_LoaderApp.bundle"; do
    [[ -d "$loc" ]] && cp -R "$loc" "$OUT/Contents/MacOS/" && cp -R "$loc" "$OUT/Contents/Resources/"
done

# Engine binaries, thinned to arm64: the bundle ships a single architecture,
# so an x86_64 slice is dead weight — half the size to map, page in and
# signature-verify at every engine launch (and every reconnect).
thin_arm64() {
    local f="$1" archs
    archs="$(lipo -archs "$f" 2>/dev/null || true)"
    if [[ "$archs" == *x86_64* && "$archs" == *arm64* ]]; then
        lipo "$f" -thin arm64 -output "$f.thin" && mv "$f.thin" "$f"
    fi
}
for core in xray tun2socks amneziawg-go hysteria; do
    if [[ -f "$ROOT/Resources/$core" ]]; then
        cp "$ROOT/Resources/$core" "$OUT/Contents/Resources/"
        thin_arm64 "$OUT/Contents/Resources/$core"
    fi
done

# Privileged helper — bundled so the app can install it (one admin prompt) to
# enable the system-wide tunnel; see HelperInstaller. The reset script is the
# helper-independent network recovery the app falls back to.
[[ -f "$SCRATCH/$CONFIG/LoaderHelper" ]] && cp "$SCRATCH/$CONFIG/LoaderHelper" "$OUT/Contents/Resources/LoaderHelper"
cp "$ROOT/Scripts/anemia-network-reset.sh" "$OUT/Contents/Resources/anemia-network-reset.sh"

# Strip any xattr detritus then ad-hoc sign so Gatekeeper lets it run locally.
xattr -cr "$OUT" 2>/dev/null || true
codesign --force --deep --sign - "$OUT" 2>/dev/null || echo "(codesign skipped)"

echo "Done: $OUT"
echo "Run:  open \"$OUT\"    (set LOADER_XRAY_PATH for the engine in dev)"
