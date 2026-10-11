#!/usr/bin/env bash
#
# Второй контур проверки Windows-порта: каждый конфиг, который собрал C#,
# прогоняется через настоящий движок (`xray run -c … -test`).
#
# Parity-тесты доказывают, что C# и Swift дают одинаковые байты. Движок
# доказывает, что эти байты вообще можно запустить: в 2026-09 один из золотых
# конфигов совпадал у Swift с Kotlin и при этом отвергался xray.
#
#   bash windows-version-alpha/Scripts/verify-configs.sh
#
# Каталог ссылок — общий с Android (links/corpus.txt), чтобы три порта сверялись
# по одному и тому же набору.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT/Android/core/src/test/resources/links/corpus.txt"
XRAY="${XRAY:-$ROOT/Resources/xray}"
OUT_DIR="${OUT_DIR:-/tmp/win-configs}"

source "$(dirname "$0")/dotnet-env.sh"

[[ -x "$XRAY" ]] || { echo "✗ нет $XRAY — на macOS он лежит в Resources/" >&2; exit 1; }
[[ -f "$FIX" ]]  || { echo "✗ нет фикстуры $FIX" >&2; exit 1; }

rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"
# Один build вместо `dotnet run` на каждую ссылку: запуск на кейс стоил бы
# полторы минуты сборки и превращал бы проверку в ceremony.
echo "→ собирает AnemiaTool"
BIN_DIR="${BIN_DIR:-/tmp/win-tool}"
"$DOTNET_ROOT/dotnet" build "$ROOT/windows-version-alpha/tools/AnemiaTool/AnemiaTool.csproj" \
    -v q --nologo -o "$BIN_DIR" >&2
TOOL=("$DOTNET_ROOT/dotnet" "$BIN_DIR/AnemiaTool.dll")
# bash 3.2 (та, что лежит в macOS) не умеет mapfile.
links=()
while IFS= read -r line; do [[ -n "$line" ]] && links+=("$line"); done < "$FIX"
echo "   кейсов в фикстуре: ${#links[@]}"

accepted=0; refused=0; unsupported=0; engine_refused=0; index=0
for link in "${links[@]}"; do
    index=$((index + 1))
    out="$("${TOOL[@]}" emit "$link" 2>/dev/null || true)"
    if [[ "$out" == error* ]]; then
        kind="$(printf '%s' "$out" | cut -f3)"
        reason="$(printf '%s' "$out" | cut -f4-)"
        # Разбор ссылки и сборка конфига — разные отказы: первое значит «порт
        # пока не знает схему», второе значит «порт знает и ошибся».
        # «Схема не портирована» — это когда отказ называется одним словом:
        # схемой. Отказ с текстом внутри (`vpn link: no supported container …`)
        # Swift формулирует так же, и его сверяет ParityLinks по общему золоту,
        # поэтому здесь он считается ordinary refusal, а не дырой порта.
        if [[ "$kind" == "unsupported-scheme" && "$reason" == "$(printf '%s' "$link" | cut -d: -f1)" ]]; then
            unsupported=$((unsupported + 1))
            echo "   · не портировано: $(printf '%s' "$link" | cut -d: -f1) — $reason"
        elif [[ "$kind" == "config" ]]; then
            refused=$((refused + 1))
            echo "   · порт отверг конфиг, кейс $index: $reason"
        else
            refused=$((refused + 1))
            echo "   · порт не разобрал ссылку, кейс $index: $kind — $reason"
        fi
        continue
    fi
    cfg="$OUT_DIR/$index.json"
    printf '%s' "$out" > "$cfg"
    if engine_out="$("$XRAY" run -c "$cfg" -test 2>&1)" && [[ "$engine_out" != *"Failed to start"* ]]; then
        accepted=$((accepted + 1))
    else
        engine_refused=$((engine_refused + 1))
        echo "$index" >> "$OUT_DIR/engine-refused"
        echo "✘ ДВИЖОК отверг кейс $index: $(printf '%s' "$engine_out" | grep -m1 'Failed to start' | cut -c1-200)"
    fi
done

total=$((accepted + refused + unsupported + engine_refused))
echo "— движок принял $accepted, отверг $engine_refused; порт отказал $refused, схем не портировано $unsupported (всего $total из ${#links[@]})"

# Пол тут не формальность: цикл, до которого не дошла ни одна ссылка, печатал бы
# «расхождений 0» и на пустом каталоге.
if [[ $total -ne ${#links[@]} ]]; then
    echo "✘ разобрались не со всеми кейсами: $total из ${#links[@]}" >&2
    exit 1
fi
# Движок отвергнутый конфиг — единственное, что краснит проверку: refusal порта
# по битой ссылке это и есть правильное поведение (часть фикстуры — ловушки).
# Исключение названо по индексу, а не «отвергнутых ровно один»: кейс 100 —
# `vless://1b564d2f-…%zz@example.com`, где все три порта честно сохраняют
# не-UUID из userinfo и печатают его как `uuid`. xray прав: это не UUID.
# Починить это значит менять разбор в Swift, Kotlin и C# разом вместе с
# фикстурой, а не подстраивать один порт под свой движок.
EXPECTED_REFUSALS="${EXPECTED_REFUSALS:-100}"
actual_refusals="$(sort -n "$OUT_DIR/engine-refused" 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
if [[ "$actual_refusals" != "$EXPECTED_REFUSALS" ]]; then
    echo "✘ движок отверг не то, что ожидалось: получили [$actual_refusals], ждали [$EXPECTED_REFUSALS]" >&2
    exit 1
fi
if [[ $accepted -eq 0 ]]; then
    echo "✘ ни один конфиг не дошёл до движка" >&2
    exit 1
fi
echo "✓ все собранные конфиги принимает настоящий xray (кроме названного кейса $EXPECTED_REFUSALS)"
