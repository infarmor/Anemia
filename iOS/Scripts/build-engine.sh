#!/usr/bin/env bash
#
# Собирает iOS/Engine/build/AnemiaEngine.xcframework — Xray-core и AmneziaWG
# одним Go-архивом для расширения-туннеля (срезы для iPhone и симулятора).
#
#   bash iOS/Scripts/build-engine.sh
#
# Первый запуск скачивает Go (go-env.sh) и исходники движков по версиям из
# Engine/go.mod, сверяя их с Engine/go.sum; дальше сборка инкрементальная.
set -euo pipefail

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE_DIR="$IOS_DIR/Engine"
OUT="$ENGINE_DIR/build/AnemiaEngine.xcframework"
source "$IOS_DIR/Scripts/go-env.sh"

WORK="$ANEMIA_CACHE/engine-build"
rm -rf "$WORK"
mkdir -p "$WORK"
cd "$ENGINE_DIR"

echo "→ исходники движков"
go mod download

# Правки Xray: копия закреплённого модуля (Go сверил его с go.sum) с
# наложенным патчем подключается через replace во временном go.mod, так что
# Engine/go.mod и кэш модулей не меняются. Патч обязан наложиться ровно на
# эту версию — иначе сборка останавливается.
XRAY_DIR="$(go list -m -f '{{.Dir}}' github.com/xtls/xray-core)"
PATCH="$ENGINE_DIR/patches/xray-v1.260327.0-ios.patch"
[[ "$XRAY_DIR" == *"@v1.260327.0" ]] || {
    echo "✗ патч написан для xray-core v1.260327.0, а в go.mod другая версия: $XRAY_DIR" >&2
    exit 1
}
cp -R "$XRAY_DIR" "$WORK/xray-core"
chmod -R u+w "$WORK/xray-core"
(cd "$WORK/xray-core" && patch -p1 -N -s -t -i "$PATCH") || {
    echo "✗ патч $PATCH не накладывается" >&2
    exit 1
}
cp go.mod "$WORK/go.mod"
cp go.sum "$WORK/go.sum"
go mod edit -modfile="$WORK/go.mod" -replace "github.com/xtls/xray-core=$WORK/xray-core"

build_slice() { # <name> <sdk> <clang target>
    local name="$1" sdk="$2" target="$3"
    local sysroot cc
    sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    cc="$(xcrun --sdk "$sdk" --find clang)"
    echo "→ движок: $name"
    mkdir -p "$WORK/$name/include/AnemiaEngine"
    CGO_ENABLED=1 GOOS=ios GOARCH=arm64 CC="$cc" \
    CGO_CFLAGS="-isysroot $sysroot -target $target -O2" \
    CGO_LDFLAGS="-isysroot $sysroot -target $target" \
        go build -buildmode=c-archive -trimpath -buildvcs=false \
            -ldflags "-s -w" -modfile "$WORK/go.mod" \
            -o "$WORK/$name/libanemia.a" .
    mv "$WORK/$name/libanemia.h" "$WORK/$name/include/AnemiaEngine/"
    cp "$ENGINE_DIR/module.modulemap" "$WORK/$name/include/AnemiaEngine/"
}

build_slice iphoneos iphoneos arm64-apple-ios17.0
build_slice iphonesimulator iphonesimulator arm64-apple-ios17.0-simulator

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework \
    -library "$WORK/iphoneos/libanemia.a" -headers "$WORK/iphoneos/include" \
    -library "$WORK/iphonesimulator/libanemia.a" -headers "$WORK/iphonesimulator/include" \
    -output "$OUT" >/dev/null
echo "✓ $OUT ($(du -sh "$OUT" | cut -f1 | tr -d ' '))"
