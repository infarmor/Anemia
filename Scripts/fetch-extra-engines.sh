#!/usr/bin/env bash
#
# Fetch the optional engines into Resources/ so build-app.sh bundles them:
#
#   amneziawg-go — the AmneziaWG / WireGuard engine (protocol 1.0 … 3.1).
#                  amneziawg-go publishes no release binaries, so it is BUILT
#                  from source here; needs Go (https://go.dev/dl) and git.
#   hysteria     — the Hysteria 2 client, from the official release.
#
# Downloads third-party code, pinned and verified by default (override to bump):
#   AWG_GO_REF / AWG_GO_COMMIT   — tag to build and the commit it must resolve to
#   HYSTERIA_VERSION / HYSTERIA_SHA256 — release and sha256 of hysteria-darwin-arm64
#   GO                            — go binary (default: `go` on PATH, else the
#                                   toolchain unpacked under /tmp/loader-build/toolchains)
#
# After building the app, update the privileged helper once (Settings →
# Network): the helper installer copies amneziawg-go into
# /Library/PrivilegedHelperTools, the only place the root helper runs it from.
#
#   bash Scripts/fetch-extra-engines.sh [awg] [hysteria]   # default: both
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${DEST:-$ROOT/Resources}"
mkdir -p "$DEST"
WANT=("$@")
[[ ${#WANT[@]} -eq 0 ]] && WANT=(awg hysteria)

# Pins verified 2026-09-14: amneziawg-go tag v3.1.20260828 (AmneziaWG 3.1);
# hysteria app/v2.12.2 (sha256 from the release's hashes.txt).
AWG_GO_REF="${AWG_GO_REF:-v3.1.20260828}"
AWG_GO_COMMIT="${AWG_GO_COMMIT:-b5928efb6ca19f0153958460c3d141f04abc5c2e}"
HYSTERIA_VERSION="${HYSTERIA_VERSION:-app/v2.12.2}"
HYSTERIA_SHA256="${HYSTERIA_SHA256:-d5850b02d0952ab5f88cd9bf37d0e84585905aba107e3f977336f1047f107d9d}"
if [[ -z "${GO:-}" ]]; then
  if command -v go >/dev/null; then GO=go
  elif [[ -x /tmp/loader-build/toolchains/go/bin/go ]]; then GO=/tmp/loader-build/toolchains/go/bin/go
  else GO=go; fi
fi

sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

build_awg() {
  command -v "$GO" >/dev/null || { echo "✗ Go is required to build amneziawg-go (https://go.dev/dl)" >&2; exit 1; }
  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  echo "→ amneziawg-go @ $AWG_GO_REF"
  git clone --quiet https://github.com/amnezia-vpn/amneziawg-go "$tmp/src"
  git -C "$tmp/src" -c advice.detachedHead=false checkout --quiet "$AWG_GO_REF"
  local commit; commit="$(git -C "$tmp/src" rev-parse HEAD)"
  echo "  commit $commit"
  if [[ -n "$AWG_GO_COMMIT" && "$commit" != "$AWG_GO_COMMIT" ]]; then
    echo "✗ $AWG_GO_REF resolved to $commit, expected $AWG_GO_COMMIT" >&2; exit 1
  fi
  (cd "$tmp/src" && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 GOTOOLCHAIN=local \
      "$GO" build -trimpath -ldflags "-s -w" -o "$DEST/amneziawg-go" .)
  chmod 0755 "$DEST/amneziawg-go"
  echo "  → $DEST/amneziawg-go"
}

fetch_hysteria() {
  local url="https://github.com/apernet/hysteria/releases/download/${HYSTERIA_VERSION}/hysteria-darwin-arm64"
  echo "→ hysteria $HYSTERIA_VERSION"
  curl -fsSL "$url" -o "$DEST/hysteria.download"
  local got; got="$(sha256_of "$DEST/hysteria.download")"
  if [[ -n "$HYSTERIA_SHA256" && "$got" != "$HYSTERIA_SHA256" ]]; then
    rm -f "$DEST/hysteria.download"
    echo "✗ checksum mismatch: expected $HYSTERIA_SHA256, got $got" >&2; exit 1
  fi
  [[ -z "$HYSTERIA_SHA256" ]] && echo "  ⚠ unverified download (sha256 $got) — set HYSTERIA_SHA256 to pin it"
  mv "$DEST/hysteria.download" "$DEST/hysteria"
  chmod 0755 "$DEST/hysteria"
  echo "  → $DEST/hysteria"
}

for engine in "${WANT[@]}"; do
  case "$engine" in
    awg) build_awg ;;
    hysteria) fetch_hysteria ;;
    *) echo "unknown engine: $engine (awg, hysteria)" >&2; exit 64 ;;
  esac
done
