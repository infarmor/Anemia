#!/usr/bin/env bash
#
# Собирает Go-движок (Xray-core + AmneziaWG) в libanemia.so для Android —
# тот же пакет iOS/Engine и те же экспорты, только кросс-компиляция через
# NDK и вместо c-archive общий объект (dlopen в c-archive не умеет).
#
#   bash Android/Scripts/build-engine.sh            # arm64-v8a, armeabi-v7a, x86_64
#   ABIS="arm64-v8a" bash Android/Scripts/build-engine.sh
#
# Результат: Android/engine/build/<abi>/{libanemia.so, libanemia_jni.so}, и
# обе скрипт сам кладёт в app/src/main/jniLibs/<abi>/.
#
# Нужно: NDK (Scripts/bootstrap.sh) и собранный для этой платформы Go-тулчейн;
# arm64-v8a проверена на этой машине, остальное — только перечислено.
set -euo pipefail

ANDROID_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$ANDROID_DIR/.." && pwd)"
ENGINE_DIR="$ROOT/iOS/Engine"                     # один движок на обе платформы
OUT="$ANDROID_DIR/engine/build"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
API=28                                            # minSdk проекта
ABIS="${ABIS:-arm64-v8a armeabi-v7a x86_64}"

[[ -d "$ENGINE_DIR" ]] || { echo "✗ нет $ENGINE_DIR" >&2; exit 1; }
source "$ROOT/iOS/Scripts/go-env.sh"              # pinned Go + кэши вне ~/go

NDK_DIR="$(ls -d "$SDK"/ndk/*/ 2>/dev/null | tail -1 || true)"
[[ -n "$NDK_DIR" ]] || { echo "✗ NDK не найден в $SDK/ndk — выполните Scripts/bootstrap.sh" >&2; exit 1; }
TOOLCHAIN="$NDK_DIR/toolchains/llvm/prebuilt/darwin-x86_64"
[[ -d "$TOOLCHAIN" ]] || { echo "✗ нет тулчейна $TOOLCHAIN" >&2; exit 1; }

# Имена целей clang в NDK не совпадают с именами ABI Android.
target_triple() {
    case "$1" in
        arm64-v8a)   echo "aarch64-linux-android" ;;
        armeabi-v7a) echo "armv7a-linux-androideabi" ;;
        x86_64)      echo "x86_64-linux-android" ;;
        *)           echo "" ;;
    esac
}

goarch_for() {
    case "$1" in
        arm64-v8a)   echo "arm64" ;;
        armeabi-v7a) echo "arm" ;;
        x86_64)      echo "amd64" ;;
        *)           echo "" ;;
    esac
}

cd "$ENGINE_DIR"
echo "→ исходники движков"
go mod download

mkdir -p "$OUT"
for abi in $ABIS; do
    triple="$(target_triple "$abi")"
    [[ -n "$triple" ]] || { echo "✗ неизвестное ABI $abi" >&2; exit 1; }
    cc="$TOOLCHAIN/bin/${triple}${API}-clang"
    [[ -x "$cc" ]] || { echo "✗ нет компилятора $cc" >&2; exit 1; }

    echo "→ движок: $abi"
    mkdir -p "$OUT/$abi"
    CGO_ENABLED=1 GOOS=android GOARCH="$(goarch_for "$abi")" \
    CC="$cc" \
    CGO_CFLAGS="--sysroot=$TOOLCHAIN/sysroot -target ${triple}${API} -O2" \
    CGO_LDFLAGS="--sysroot=$TOOLCHAIN/sysroot -target ${triple}${API} -L$TOOLCHAIN/lib" \
        go build -buildmode=c-shared -trimpath -buildvcs=false \
            -ldflags "-s -w" -o "$OUT/$abi/libanemia.so" .
    echo "   ✓ $OUT/$abi/libanemia.so ($(du -h "$OUT/$abi/libanemia.so" | cut -f1 | tr -d ' '))"

    # JNI-обёртка: Go экспортирует чистые C-функции, а JVM из Kotlin видит
    # только `Java_…`. Собирается отдельно и не линкуется с libanemia.so —
    # находит её через dlopen, так что порядок загрузки решает сама система.
    echo "→ jni-шим: $abi"
    "$cc" --sysroot="$TOOLCHAIN/sysroot" -target "${triple}${API}"         -O2 -fPIC -shared -Wall -Werror         -o "$OUT/$abi/libanemia_jni.so" "$ANDROID_DIR/engine/jni/anemia_jni.c"
    echo "   ✓ $OUT/$abi/libanemia_jni.so"
done

echo "→ в jniLibs"
for abi in $ABIS; do
    dest="$ANDROID_DIR/app/src/main/jniLibs/$abi"
    mkdir -p "$dest"
    cp "$OUT/$abi/libanemia.so" "$OUT/$abi/libanemia_jni.so" "$dest/"
done
echo "✓ готово; дальше: cd Android && ./gradlew :app:assembleDebug"
