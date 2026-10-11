#!/usr/bin/env bash
#
# Третий контур для трафика Windows-порта: документ, который C# прочитал из
# записей Swift и переписал своими байтами, перечитывает настоящий
# Swift-декодер (`LoaderTool ledger-read`). Результат сверяется с тем, что тот
# же декодер выдаёт на исходной записи Swift.
#
# Это проверяет не «C# понял C#», а путь приложения: `traffic.json` пишется этим
# портом при работе, а читаётся при старте — и ровно те байты должны остаться
# понятными Mac'у и iPhone, которые откроют тот же файл (синхронизация, перенос
# с телефона). Здесь видны сдвиг reference date (секунды от 2001-01-01, а не от
# эпохи Unix), плоский массив «ключ, значение» для словаря с UUID-ключами и его
# ВЕРХНИЙ регистр, и то, что пропущенная опция не пишется как null.
#
# Второй проход тем же C# (out → out2) добавлен потому, что приложение делает
# именно так: прочитал, дописал, сохранил. Документ, который после второго
# прохода становится другим, тихо теряет дни при каждом перезапуске.
#
#   bash windows-version-alpha/Scripts/test.sh
#   bash windows-version-alpha/Scripts/verify-traffic.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT/Android/core/src/test/resources/score/ledger.golden.txt"
OUT_DIR="${OUT_DIR:-/tmp/win-traffic}"
SCRATCH="${SCRATCH:-/tmp/loader-build/win}"

source "$(dirname "$0")/dotnet-env.sh"

[[ -f "$FIX" ]] || { echo "✗ нет $FIX (общий эталон, его печатает golden-score.sh)" >&2; exit 1; }

BIN_DIR="${BIN_DIR:-/tmp/win-traffic-tool}"
echo "→ собирает AnemiaTool"
rm -rf "$BIN_DIR"
"$DOTNET_ROOT/dotnet" build "$ROOT/windows-version-alpha/tools/AnemiaTool/AnemiaTool.csproj" \
    -v q --nologo --no-incremental -o "$BIN_DIR" >&2
CS=("$DOTNET_ROOT/dotnet" "$BIN_DIR/AnemiaTool.dll")

echo "→ собирает LoaderTool"
(cd "$ROOT" && swift build --scratch-path "$SCRATCH" --product LoaderTool 2>&1 | tail -1)
SWIFT_TOOL="$SCRATCH/out/Products/Debug/LoaderTool"
[[ -x "$SWIFT_TOOL" ]] || { echo "✗ нет $SWIFT_TOOL" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"

# Пары «кейс ↔ документ Swift» из эталона.
pairs="$(awk '
    /^=== /    { name = substr($0, 5) }
    /^json\t/  { print name "\t" substr($0, 6) }
' "$FIX")"

fail=0
count=0
expected="$(grep -c . <<<"$pairs")"
while IFS=$'\t' read -r name doc; do
    [[ -n "${name:-}" ]] || continue
    printf '%s' "$doc" > "$WORK/$name-swift.json"
    if ! "${CS[@]}" traffic "$WORK/$name-swift.json" "$OUT_DIR/$name.json" 2>"$WORK/err"; then
        echo "✗ $name: C# не переписал документ: $(head -1 "$WORK/err")"
        fail=$((fail + 1))
        continue
    fi
    # Нет файла — это не «пустой ряд», это пропущенный кейс: верб мог вообще
    # не существовать в собранном бинаре.
    [[ -s "$OUT_DIR/$name.json" ]] || { echo "✗ $name: C# записал пустой файл"; fail=$((fail + 1)); continue; }
    if ! "${CS[@]}" traffic "$OUT_DIR/$name.json" "$OUT_DIR/$name-again.json" 2>"$WORK/err"; then
        echo "✗ $name: C# не перечитал собственную запись: $(head -1 "$WORK/err")"
        fail=$((fail + 1))
        continue
    fi

    both="$("$SWIFT_TOOL" ledger-read "$WORK/$name-swift.json" \
        "$OUT_DIR/$name.json" "$OUT_DIR/$name-again.json")"
    fromSwift="$(printf '%s\n' "$both" | sed -n 1p | cut -f2-)"
    fromCSharp="$(printf '%s\n' "$both" | sed -n 2p | cut -f2-)"
    fromAgain="$(printf '%s\n' "$both" | sed -n 3p | cut -f2-)"
    if [[ "$(printf '%s\n' "$both" | grep -c .)" != 3 ]]; then
        echo "✗ $name: Swift прочитал не все три документа"
        printf '%s\n' "$both" | sed 's/^/   /'
        fail=$((fail + 1))
        continue
    fi
    count=$((count + 1))
    if [[ "$fromSwift" == throw* || "$fromCSharp" == throw* ]]; then
        echo "✗ $name: Swift не прочитал запись C# (swift: $fromSwift, c#: $fromCSharp)"
        fail=$((fail + 1))
        continue
    fi
    if [[ "$fromCSharp" != "$fromSwift" ]]; then
        echo "✗ $name: Swift прочитал запись C# иначе"
        echo "   ждали $fromSwift"
        echo "   получил $fromCSharp"
        fail=$((fail + 1))
    elif [[ "$fromAgain" != "$fromCSharp" ]]; then
        echo "✗ $name: второй проход C# изменил документ"
        echo "   первый  $fromCSharp"
        echo "   второй  $fromAgain"
        fail=$((fail + 1))
    fi
done <<< "$pairs"

# Пустая выборка — это не «расхождений нет»: кейсы могли просто не дойти.
if (( expected == 0 || count != expected )); then
    echo "✗ сверено $count из $expected документов — часть кейсов не дошла до Swift" >&2
    exit 1
fi

echo "✓ документов C# перечитано Swift-декодером без потерь: $count, расхождений: $fail"
[[ $fail -eq 0 ]]
