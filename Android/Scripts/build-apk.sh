#!/usr/bin/env bash
#
# Собирает и подписывает релизные APK — то, что можно положить на телефон.
#
#   bash Android/Scripts/build-apk.sh
#   ANEMIA_APK_ABIS="arm64-v8a" bash Android/Scripts/build-apk.sh   # только одно ABI
#   ANEMIA_APK_ABIS="" bash Android/Scripts/build-apk.sh            # только universal
#   ANEMIA_APK_KEYSTORE=/path/anemia.jks ANEMIA_APK_KEYSTORE_PASSWORD=… \
#   ANEMIA_APK_KEYSTORE_ALIAS=anemia ANEMIA_APK_KEY_PASSWORD=… bash Android/Scripts/build-apk.sh
#
# Ключ берётся в этом порядке: явный из окружения → штатный ключ раздачи
# (`~/Library/Application Support/Anemia/anemia-release.keystore`, пароль в
# соседнем файле 0600) → отладочный. Про отладочный скрипт говорит вслух: такой
# APK ставится, но раздавать его нельзя — подпись у него общая со всеми, кто
# когда-либо запускал Gradle на этой машине.
#
# Кроме универсального APK делаются сборки по одному ABI — на телефоне
# достаточно `anemia-release-arm64-v8a.apk`. Нативные библиотеки по умолчанию
# сжаты (`ANEMIA_APK_COMPRESS_LIBS=0` — нет): движок составляет 93 % архива, и
# в сжатом виде APK получается втрое меньше, а на телефоне занимает свои
# 33 МБ всё равно.
#
# Универсальная сборка идёт с `--rerun-tasks`: без этого флага Gradle трижды
# ответил «UP-TO-DATE» по APK, который пережил вечернюю правку `:core`, и в
# хвосте архива лежали байты, не принадлежащие ни одной записи. Для артефакта,
# который уходит человеку, это не «быстрее», а другой файл.
set -euo pipefail

ANDROID_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
APKSIGNER="$(ls -d "$SDK/build-tools"/*/ 2>/dev/null | tail -1)apksigner"
OUT_DIR="$ANDROID_DIR/app/build/outputs/apk/release"
UNSIGNED="$OUT_DIR/app-release-unsigned.apk"
DIST_DIR="$ANDROID_DIR/dist"      # сюда ложатся подписанные артефакты
ABIS="${ANEMIA_APK_ABIS-arm64-v8a armeabi-v7a x86_64}"
# Движок — 93 % APK; сжатым он весит втрое меньше. По умолчанию включено,
# `ANEMIA_APK_COMPRESS_LIBS=0` возвращает распаковку на лету (mmap из APK).
COMPRESS="${ANEMIA_APK_COMPRESS_LIBS-1}"

[[ -x "$APKSIGNER" ]] || { echo "✗ нет $APKSIGNER — установите build-tools" >&2; exit 1; }
if [[ -z "${JAVA_HOME:-}" ]]; then
    brew_jdk="$(brew --prefix openjdk@21 2>/dev/null || true)"
    [[ -n "$brew_jdk" ]] || { echo "✗ JAVA_HOME не задан и openjdk@21 через brew не найден" >&2; exit 1; }
    export JAVA_HOME="$brew_jdk/libexec/openjdk.jdk/Contents/Home"
fi

KEYSTORE="${ANEMIA_APK_KEYSTORE:-}"
ALIAS="${ANEMIA_APK_KEYSTORE_ALIAS:-androiddebugkey}"
STORE_PASS="${ANEMIA_APK_KEYSTORE_PASSWORD:-}"
KEY_PASS="${ANEMIA_APK_KEY_PASSWORD:-}"
DEFAULT_KEYSTORE="$HOME/Library/Application Support/Anemia/anemia-release.keystore"
DEFAULT_PASSFILE="$HOME/Library/Application Support/Anemia/anemia-release.password"
if [[ -n "$KEYSTORE" ]]; then
    [[ -f "$KEYSTORE" ]] || { echo "✗ нет файла ключа $KEYSTORE" >&2; exit 1; }
    [[ -n "$STORE_PASS" && -n "$KEY_PASS" ]] || {
        echo "✗ для своего ключа нужны ANEMIA_APK_KEYSTORE_PASSWORD и ANEMIA_APK_KEY_PASSWORD" >&2; exit 1; }
    SIGNED_WITH="ключом $KEYSTORE (alias $ALIAS)"
elif [[ -f "$DEFAULT_KEYSTORE" && -f "$DEFAULT_PASSFILE" ]]; then
    KEYSTORE="$DEFAULT_KEYSTORE"
    ALIAS=anemia
    STORE_PASS="$(cat "$DEFAULT_PASSFILE")"
    KEY_PASS="$STORE_PASS"
    SIGNED_WITH="ключом раздачи $KEYSTORE"
else
    KEYSTORE="$HOME/.android/debug.keystore"
    ALIAS=androiddebugkey
    # Заданные пароли здесь игнорируются: у отладочного ключа они фиксированы,
    # и иначе «забыл указать ANEMIA_APK_KEYSTORE, но указал пароль» выглядело бы
    # как «wrong password», а не как то, что это вообще не тот ключ.
    STORE_PASS=android
    KEY_PASS=android
    SIGNED_WITH="ОТЛАДОЧНЫМ ключом $KEYSTORE — ставится, но раздавать нельзя"
fi
export ANEMIA_STORE_PASS="$STORE_PASS" ANEMIA_KEY_PASS="$KEY_PASS"

# Одна сборка + подпись. `$1` — список ABI через пробел (пусто = все три),
# `$2` — имя итогового файла, `$3` — «полная» пересборка или нет.
build_and_sign() {
    local abis="$1" name="$2" fresh="$3"
    local args=(":app:assembleRelease" "-PanemiaCompressLibs=$COMPRESS")
    # `if`, а не `[[ ]] &&`: в bundled bash 3.2 пустой массив под `set -u` —
    # «unbound variable», а неудачная проверка в конце строки роняет скрипт.
    if [[ -n "$abis" ]]; then args+=("-PanemiaAbi=$abis"); fi
    if [[ "$fresh" == "fresh" ]]; then args+=("--rerun-tasks"); fi
    echo "→ $name (${abis:-все ABI})"
    (cd "$ANDROID_DIR" && ./gradlew "${args[@]}" --console=plain | tail -3)
    [[ -f "$UNSIGNED" ]] || { echo "✗ Gradle не оставил $UNSIGNED" >&2; exit 1; }
    local out="$OUT_DIR/$name.apk"
    rm -f "$out"
    # `--out`, а не подпись на месте: unsigned-артефакт остаётся как
    # свидетельство, что APK отличается от него только подписью. `env:` держит
    # пароли вне argv, где их видно в `ps`.
    "$APKSIGNER" sign --ks "$KEYSTORE" --ks-key-alias "$ALIAS" \
        --ks-pass env:ANEMIA_STORE_PASS --key-pass env:ANEMIA_KEY_PASS \
        --out "$out" "$UNSIGNED"
    # В `dist/`, а не в каталог AGP: следующая сборка того же варианта чистит
    # свой выходной каталог, и три подписанных APK по ABI исчезали из него
    # ровно в тот момент, когда собирался универсальный (проверено).
    cp "$out" "$DIST_DIR/"
    # Байты, а не `du -h`: на APFS свежая запись может занимать на диске на
    # десятки МБ больше или меньше собственного размера.
    printf '   ✓ %s (%s Б)\n' "$name.apk" "$(stat -f%z "$DIST_DIR/$name.apk")"
}

mkdir -p "$OUT_DIR" "$DIST_DIR"
rm -f "$DIST_DIR"/anemia-release*.apk   # зачерствевшие артефакты прошлой сборки
# Универсальная — ПЕРВОЙ и полная: она перечитывает исходники, и всё остальное
# строится уже из тех же классов. Порядок «сначала сплиты инкрементально, полная
# пересборка последней» давал APK по ABI из прошлых `.class`: правка в дереве
# есть, в архиве её нет (проверено: пересборка без единой правки изменила хэш
# arm64-архива). Последняя полная сборка возвращала дереву обычное состояние —
# теперь это делает первая, а порядок шагов больше не важен для содержимого.
build_and_sign "" "anemia-release" fresh
for abi in $ABIS; do
    build_and_sign "$abi" "anemia-release-$abi" incremental
done

echo "→ подпись"
for apk in "$DIST_DIR"/anemia-release*.apk; do
    printf '   %s → ' "$(basename "$apk")"
    "$APKSIGNER" verify --print-certs "$apk" | sed -n 's/.*SHA-1 digest: //p'
done
unset ANEMIA_STORE_PASS ANEMIA_KEY_PASS
echo "✓ подписаны $SIGNED_WITH"
