#!/usr/bin/env bash
#
# Fetch the Xray-core and tun2socks binaries the app bundles at runtime, as
# universal (arm64 + x86_64) files under Resources/.
#
# `Scripts/build-app.sh` then thins every bundled engine to arm64 before it
# signs, on purpose — so a single-arch arm64 file in Resources/ is what the app
# has been running with here, and this script is the path that would show you
# the x86_64 slice going missing: the arch checks below are what makes that loud
# instead of a quiet one-arch "Done".
#
# NOTE: This downloads third-party release binaries and verifies their SHA256
# against the pinned checksums below. If you bump XRAY_VERSION, refresh the
# hashes from the official release page first. Nothing here runs automatically
# during build.
#
set -euo pipefail

XRAY_VERSION="${XRAY_VERSION:-v26.3.27}"
# SHA256 of the per-arch release zips, keyed by "$VERSION/$asset".
# v26.3.27 — matches the engine shipped in Resources/xray. The 26.x line
# removed `allowInsecure`, mKCP seed/header and the QUIC + HTTP/2 stream
# transports; the app's config builder and link parser target exactly this.
XRAY_SHA256_arm64="2e93a67e8aa1936ecefb307e120830fcbd4c643ab9b1c46a2d0838d5f8409eaf"
XRAY_SHA256_x86_64="f5b0471d3459eff1b82e48af0aeac186abcc3298210070afbbbd8437a4e8b203"

TUN2SOCKS_VERSION="${TUN2SOCKS_VERSION:-v2.7.0}"
TUN2SOCKS_SHA256_arm64="TUN2SOCKS_SHA256_arm64_PLACEHOLDER"
TUN2SOCKS_SHA256_x86_64="TUN2SOCKS_SHA256_x86_64_PLACEHOLDER"
# Verify=off only on explicit request (e.g. fetching a brand-new release to
# obtain fresh hashes). Never set these by default. Each core gets its own
# flag: XRAY_SKIP_CHECKSUM=1 must not silently also un-verify the
# tun2socks binary — that one boots inside the privileged tunnel.
XRAY_VERIFY_OFF="${XRAY_SKIP_CHECKSUM:-0}"
TUN2SOCKS_VERIFY_OFF="${TUN2SOCKS_SKIP_CHECKSUM:-0}"

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

# lipo -create exits 0 when only one of its inputs was readable: the result is
# a "fat" file with a single architecture, and the script would still print
# "Done". Measured on this Mac (`lipo -create -output out one.bin missing.bin`
# → exit 0, `lipo -info out` → one arch). So both the inputs and the produced
# slices are checked, and the destination is only replaced after that passed —
# a failed fetch must not leave the bundle holding half an engine.
require_input() { # path label
  [[ -f "$1" ]] || {
    echo "✗ $2: распаковка не дала $1" >&2
    echo "  содержимое: $(find "$(dirname "$(dirname "$1")")" -type f 2>/dev/null | sed -n '1,6p' | tr '\n' ' ')" >&2
    exit 1
  }
}

require_arches() { # file label arch-prefix…
  local file="$1"; shift
  local label="$1"; shift
  local have slice
  have="$(lipo -archs "$file" 2>/dev/null || true)"
  for want in "$@"; do
    # Prefix, not equality: a slice can be arm64e, and demanding the literal
    # name would refuse a perfectly good download. What must not happen is a
    # whole architecture going missing while the script says "Done".
    slice=""
    for found in $have; do
      case "$found" in "$want"*) slice="$found"; break ;; esac
    done
    [[ -n "$slice" ]] || {
      echo "✗ $label: в собранном бинарнике нет $want (есть: ${have:-ничего})" >&2
      exit 1
    }
  done
}

# Write beside the destination and rename, so a failure above never touches the
# file the app already runs from.
install_bin() { # src dest
  mv -f "$1" "$2"
  chmod +x "$2"
}

fetch_xray() {
  # macOS Xray release assets are per-arch zips: Xray-macos-arm64-v8a.zip etc.
  local tmp; tmp="$(mktemp -d)"
  # The path is bound when the trap is set: `$tmp` is local, so a trap holding
  # the NAME would run `rm -rf ""` after this function returned (and the second
  # fetch's trap would already have replaced it anyway).
  trap "rm -rf '$tmp'" EXIT
  for arch in arm64-v8a 64; do
    local url="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-macos-${arch}.zip"
    echo "  fetching $url"
    curl -fsSL "$url" -o "$tmp/xray-$arch.zip"
    if [[ "$XRAY_VERIFY_OFF" == "1" ]]; then
      echo "  ⚠ XRAY_SKIP_CHECKSUM=1 — skipping checksum verification"
    else
      local expected
      if [[ "$arch" == "arm64-v8a" ]]; then expected="$XRAY_SHA256_arm64"; else expected="$XRAY_SHA256_x86_64"; fi
      verify_or_bail "$tmp/xray-$arch.zip" "$expected" "Xray-macos-${arch}.zip" XRAY
    fi
    unzip -o -q "$tmp/xray-$arch.zip" -d "$tmp/xray-$arch"
  done
  # Merge into a universal binary.
  require_input "$tmp/xray-arm64-v8a/xray" "Xray-macos-arm64-v8a.zip"
  require_input "$tmp/xray-64/xray" "Xray-macos-64.zip"
  lipo -create -output "$tmp/xray.universal" \
    "$tmp/xray-arm64-v8a/xray" "$tmp/xray-64/xray"
  require_arches "$tmp/xray.universal" xray arm64 x86_64
  install_bin "$tmp/xray.universal" "$DEST/xray"
  rm -rf "$tmp"
  echo "  → $DEST/xray"
  file "$DEST/xray"
}

fetch_tun2socks() {
  # xjasonlyu/tun2socks release assets are per-arch zips. The helper's
  # tun:// device + socks5 proxy arguments match this project's flags
  # (--device, --proxy, --loglevel, --mtu, --tcp-auto-tuning).
  local tmp; tmp="$(mktemp -d)"
  trap "rm -rf '$tmp'" EXIT
  for arch in arm64 amd64; do
    local url="https://github.com/xjasonlyu/tun2socks/releases/download/${TUN2SOCKS_VERSION}/tun2socks-darwin-${arch}.zip"
    echo "  fetching $url"
    curl -fsSL "$url" -o "$tmp/tun2socks-$arch.zip"
    if [[ "$TUN2SOCKS_VERIFY_OFF" == "1" ]]; then
      echo "  ⚠ TUN2SOCKS_SKIP_CHECKSUM=1 — skipping checksum verification"
    else
      local expected
      if [[ "$arch" == "arm64" ]]; then expected="$TUN2SOCKS_SHA256_arm64"; else expected="$TUN2SOCKS_SHA256_x86_64"; fi
      verify_or_bail "$tmp/tun2socks-$arch.zip" "$expected" "tun2socks-darwin-${arch}.zip" TUN2SOCKS
    fi
    unzip -o -q "$tmp/tun2socks-$arch.zip" -d "$tmp/tun2socks-$arch"
  done
  # Merge into a universal binary (asset layout: <name>-darwin-<arch>/tun2socks).
  # `-print -quit`, not `| head -1`: under pipefail a multi-match find gets
  # SIGPIPE'd (exit 141) and would fake-fail the whole script.
  local arm_bin x86_bin
  arm_bin="$(find "$tmp/tun2socks-arm64" -name tun2socks -type f -print -quit)"
  x86_bin="$(find "$tmp/tun2socks-amd64" -name tun2socks -type f -print -quit)"
  [[ -n "$arm_bin" && -n "$x86_bin" ]] || { echo "✗ tun2socks binary not found in zips" >&2; exit 1; }
  lipo -create -output "$tmp/tun2socks.universal" "$arm_bin" "$x86_bin"
  require_arches "$tmp/tun2socks.universal" tun2socks arm64 x86_64
  install_bin "$tmp/tun2socks.universal" "$DEST/tun2socks"
  rm -rf "$tmp"
  echo "  → $DEST/tun2socks"
  file "$DEST/tun2socks"
}

# file expected asset-name VAR_PREFIX — bail with instructions when the pin
# is still a placeholder.
verify_or_bail() { # file expected asset var_prefix
  case "$2" in
    *_PLACEHOLDER)
      echo "  ✗ No pinned SHA256 for $3 ($TUN2SOCKS_VERSION/$XRAY_VERSION)." >&2
      echo "    Get the official hash, set ${4}_SHA256_arm64/${4}_SHA256_x86_64 in this" >&2
      echo "    script, and re-run. (Or ${4}_SKIP_CHECKSUM=1 to bypass once, at your own risk.)" >&2
      exit 1 ;;
  esac
  check_sum "$1" "$2"
}

fetch_xray
fetch_tun2socks
echo "Done. Remember to codesign bundled binaries for a release build."
