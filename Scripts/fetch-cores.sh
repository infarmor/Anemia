#!/usr/bin/env bash
#
# Fetch the Xray-core and tun2socks binaries the app bundles at runtime.
# Produces universal (arm64 + x86_64) binaries under Resources/.
#
# NOTE: This downloads third-party release binaries. Review the pinned versions
# and checksums before running. Nothing here runs automatically during build.
#
set -euo pipefail

XRAY_VERSION="${XRAY_VERSION:-v25.8.3}"
DEST="${DEST:-$(cd "$(dirname "$0")/.." && pwd)/Resources}"
mkdir -p "$DEST"

echo "→ Destination: $DEST"
echo "→ Xray-core:   $XRAY_VERSION"

fetch_xray() {
  # macOS Xray release assets are per-arch zips: Xray-macos-arm64-v8a.zip etc.
  local tmp; tmp="$(mktemp -d)"
  for arch in arm64-v8a 64; do
    local url="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-macos-${arch}.zip"
    echo "  fetching $url"
    curl -fsSL "$url" -o "$tmp/xray-$arch.zip"
    unzip -o -q "$tmp/xray-$arch.zip" -d "$tmp/xray-$arch"
  done
  # Merge into a universal binary.
  lipo -create -output "$DEST/xray" \
    "$tmp/xray-arm64-v8a/xray" "$tmp/xray-64/xray"
  chmod +x "$DEST/xray"
  rm -rf "$tmp"
  echo "  → $DEST/xray"
  file "$DEST/xray"
}

# tun2socks (xjasonlyu/tun2socks) can be built from source with the local Go
# toolchain instead of downloading a binary:
#
#   GOOS=darwin GOARCH=arm64 go build -o tun2socks-arm64 github.com/xjasonlyu/tun2socks/v2
#   GOOS=darwin GOARCH=amd64 go build -o tun2socks-amd64 github.com/xjasonlyu/tun2socks/v2
#   lipo -create -output Resources/tun2socks tun2socks-arm64 tun2socks-amd64
#
# Building from source is preferable for a tool that runs as root.

fetch_xray
echo "Done. Remember to codesign bundled binaries for a release build."
