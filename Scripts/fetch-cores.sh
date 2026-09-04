#!/usr/bin/env bash
#
# Fetch the Xray-core and tun2socks binaries the app bundles at runtime.
# Produces universal (arm64 + x86_64) binaries under Resources/.
#
# NOTE: This downloads third-party release binaries and verifies their SHA256
# against the pinned checksums below. If you bump XRAY_VERSION, refresh the
# hashes from the official release page first. Nothing here runs automatically
# during build.
#
set -euo pipefail

XRAY_VERSION="${XRAY_VERSION:-v25.8.3}"
# SHA256 of the per-arch release zips, keyed by "$VERSION/$asset".
XRAY_SHA256_arm64="XRAY_SHA256_arm64_PLACEHOLDER"
XRAY_SHA256_x86_64="XRAY_SHA256_x86_64_PLACEHOLDER"
# Verify=off only on explicit request (e.g. fetching a brand-new release to
# obtain fresh hashes). Never set this by default.
VERIFY_OFF="${XRAY_SKIP_CHECKSUM:-0}"

DEST="${DEST:-$(cd "$(dirname "$0")/.." && pwd)/Resources}"
mkdir -p "$DEST"

echo "→ Destination: $DEST"
echo "→ Xray-core:   $XRAY_VERSION"

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else sha256sum "$1" | cut -d' ' -f1; fi
}

check_sum() { # file expected
  local got
  got="$(sha256_of "$1")"
  if [[ "$got" != "$2" ]]; then
    echo "✗ Checksum mismatch for $1:" >&2
    echo "  expected $2" >&2
    echo "  got      $got" >&2
    exit 1
  fi
}

fetch_xray() {
  # macOS Xray release assets are per-arch zips: Xray-macos-arm64-v8a.zip etc.
  local tmp; tmp="$(mktemp -d)"
  for arch in arm64-v8a 64; do
    local url="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-macos-${arch}.zip"
    echo "  fetching $url"
    curl -fsSL "$url" -o "$tmp/xray-$arch.zip"
    if [[ "$VERIFY_OFF" == "1" ]]; then
      echo "  ⚠ XRAY_SKIP_CHECKSUM=1 — skipping checksum verification"
    else
      local expected
      if [[ "$arch" == "arm64-v8a" ]]; then expected="$XRAY_SHA256_arm64"; else expected="$XRAY_SHA256_x86_64"; fi
      case "$expected" in
        *_PLACEHOLDER)
          echo "  ✗ No pinned SHA256 for Xray-macos-${arch}.zip ($XRAY_VERSION)." >&2
          echo "    Get the official hash, set XRAY_SHA256_arm64/XRAY_SHA256_x86_64 in this" >&2
          echo "    script, and re-run. (Or XRAY_SKIP_CHECKSUM=1 to bypass once, at your own risk.)" >&2
          exit 1 ;;
      esac
      check_sum "$tmp/xray-$arch.zip" "$expected"
    fi
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

fetch_xray
echo "Done. Remember to codesign bundled binaries for a release build."
