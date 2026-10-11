#!/usr/bin/env bash
#
# Sourced by build-engine.sh: puts a pinned Go toolchain on PATH.
#
# Go is not installed system-wide. The official archive is downloaded once
# into ~/Library/Caches/Anemia (outside iCloud, safe to delete — it comes back
# on the next build), checked against its sha256, and used from there. The
# module and build caches live next to it, so nothing lands in ~/go.
#
#   ANEMIA_CACHE — cache root (default ~/Library/Caches/Anemia)
#
GO_VERSION="1.27.1"
GO_SHA256="ee215d57e0ec269c60cc9ceca68e6bda321ba9ee5afe24f4b0988703c2d87d12"

ANEMIA_CACHE="${ANEMIA_CACHE:-$HOME/Library/Caches/Anemia}"
GOROOT_DIR="$ANEMIA_CACHE/toolchains/go$GO_VERSION"

if [[ ! -x "$GOROOT_DIR/bin/go" ]]; then
    archive="go$GO_VERSION.darwin-arm64.tar.gz"
    tmp="$(mktemp -d)"
    echo "→ Go $GO_VERSION: скачиваю $archive с go.dev"
    curl -fL --progress-bar "https://go.dev/dl/$archive" -o "$tmp/$archive"
    got="$(shasum -a 256 "$tmp/$archive" | cut -d' ' -f1)"
    if [[ "$got" != "$GO_SHA256" ]]; then
        rm -rf "$tmp"
        echo "✗ sha256 не совпал: ожидался $GO_SHA256, получен $got" >&2
        exit 1
    fi
    mkdir -p "$tmp/go$GO_VERSION"
    tar -xzf "$tmp/$archive" -C "$tmp/go$GO_VERSION" --strip-components 1
    mkdir -p "$(dirname "$GOROOT_DIR")"
    rm -rf "$GOROOT_DIR"
    mv "$tmp/go$GO_VERSION" "$GOROOT_DIR"
    rm -rf "$tmp"
fi

export GOROOT="$GOROOT_DIR"
export PATH="$GOROOT_DIR/bin:$PATH"
export GOPATH="$ANEMIA_CACHE/gopath"
export GOMODCACHE="$ANEMIA_CACHE/gomod"
export GOCACHE="$ANEMIA_CACHE/gocache"
# Never let a go.mod line fetch a different toolchain behind our back.
export GOTOOLCHAIN=local
