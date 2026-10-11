#!/usr/bin/env bash
#
# Четвёртый контур Windows-порта: бандл переноса, который C# прочитал из кейса и
# записал своими байтами, перечитывает настоящий Swift-декодер
# (`LoaderTool sync-read`). Результат сверяется с тем рядом `file-read` /
# `link-read`, который тот же декодер выдал наdocument'е Swift.
#
# Это проверяет не «C# понял C#», а перенос: файл `.anemia` с Windows должен
# открыться на Mac и на iPhone, а QR-ссылка — прочитаться их камерой. Здесь
# видны сырой DEFLATE вместо zlib-потока (Apple пишет `.zlib` как RFC 1951 без
# заголовка), побайтовый компакт-JSON с сортировкой ключей, escaping solidus'а,
# и то, что пропущенная опция не пишется как null.
#
#   bash windows-version-alpha/Scripts/test.sh
#   bash windows-version-alpha/Scripts/verify-sync.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT/Android/core/src/test/resources/sync/cases.golden.txt"
CASES="$ROOT/Android/core/src/test/resources/sync/cases"
OUT_DIR="${OUT_DIR:-/tmp/win-sync}"
SCRATCH="${SCRATCH:-/tmp/loader-build/win}"

source "$(dirname "$0")/dotnet-env.sh"

[[ -f "$FIX" && -d "$CASES" ]] || { echo "✗ нет фикстур sync/ (общий эталон, его печатает golden-sync.sh)" >&2; exit 1; }

BIN_DIR="${BIN_DIR:-/tmp/win-sync-tool}"
echo "→ собирает AnemiaTool"
rm -rf "$BIN_DIR"
"$DOTNET_ROOT/dotnet" build "$ROOT/windows-version-alpha/tools/AnemiaTool/AnemiaTool.csproj" \
    -v q --nologo --no-incremental -o "$BIN_DIR" >&2
CS=("$DOTNET_ROOT/dotnet" "$BIN_DIR/AnemiaTool.dll")

echo "→ собирает LoaderTool"
(cd "$ROOT" && swift build --scratch-path "$SCRATCH" --product LoaderTool 2>&1 | tail -1)
SWIFT_TOOL="$SCRATCH/out/Products/Debug/LoaderTool"
[[ -x "$SWIFT_TOOL" ]] || { echo "✗ нет $SWIFT_TOOL" >&2; exit 1; }

rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"
echo "→ C# пишет файловую и ссылочную формы кейсов Swift"
"${CS[@]}" sync "$CASES" "$OUT_DIR" | grep -c $'\t' >/dev/null

fail=0
checked=0
# Пары «кейс ↔ row-эталон» из golden: file-read у кейсов kind=file,
# link-read — у kind=link.
while IFS=$'\t' read -r name row want; do
    [[ -n "${name:-}" ]] || continue
    if [[ "$row" == "file-read" ]]; then
        file="$OUT_DIR/$name.anemia"
    else
        file="$OUT_DIR/$name.link.txt"
    fi
    if [[ ! -s "$file" ]]; then
        echo "✗ $name: C# не записал $file"
        fail=$((fail + 1))
        continue
    fi
    got="$("$SWIFT_TOOL" sync-read "$file" | cut -f3-)"
    if [[ "$got" != "$want" ]]; then
        echo "✗ $name ($row): Swift прочитал файл C# иначе"
        echo "    ждал: ${want:0:160}"
        echo "    получил: ${got:0:160}"
        fail=$((fail + 1))
    fi
    checked=$((checked + 1))
done < <(awk '
    /^=== /        { name = substr($0, 5) }
    /^file-read\t/ { print name "\tfile-read\t" substr($0, 11) }
    /^link-read\t/ { print name "\tlink-read\t" substr($0, 11) }
' "$FIX")

expected="$(awk '/^file-read\t/ || /^link-read\t/' "$FIX" | grep -c .)"
if [[ "$checked" -ne "$expected" ]]; then
    echo "✗ проверено $checked пар, а кейсов с такой строкой $expected — контур молчит на половине"
    exit 1
fi
if [[ "$fail" -gt 0 ]]; then
    echo "✗ расхождений: $fail из $checked"
    exit 1
fi
echo "✓ Swift перечитал бандлы Windows без потерь: $checked"
