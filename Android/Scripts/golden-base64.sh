#!/usr/bin/env bash
#
# Пересоздаёт эталон гибкого base64: что Swift-декодер возвращает на каждую
# строку cases.txt (hex или nil). Порт на Kotlin переписывает декод с нуля, и
# расхождения здесь — это ровно те мусорные входы, которые на глаз не проверяешь.
# Вторым файлом идёт таблица пробелов Foundation (`trim-sets.tsv`) — теми же
# символами пользуются `trimSpaceLike` и `trimFoundationSpaces` на обеих сторонах.
#
#   bash Android/Scripts/golden-base64.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT/Android/core/src/test/resources/base64"
SCRATCH="${SCRATCH:-/tmp/loader-build/mac}"

cd "$ROOT"
swift build --scratch-path "$SCRATCH" --product LoaderTool 2>&1 | tail -1
TOOL="$SCRATCH/out/Products/Debug/LoaderTool"
[[ -x "$TOOL" ]] || { echo "✗ нет $TOOL" >&2; exit 1; }

"$TOOL" b64 "$FIX/cases.txt" > "$FIX/cases.golden.txt"
echo "✓ $FIX/cases.golden.txt ($(wc -l < "$FIX/cases.golden.txt" | tr -d ' ') строк)"

# Набор символов, которые Foundation снимает как `.whitespaces` и
# `.whitespacesAndNewlines`. Порт строит `trimSpaceLike`/`trimFoundationSpaces`
# руками, и сверять их надо не с названием набора, а с членством: `Char.isWhitespace`
# на десктопной JVM и на Android'е считает пробелами разное (тут NBSP — пробел,
# там нет), поэтому золотая таблица задаёт ответ один раз и для обеих платформ.
cat > /tmp/trimsets-main.swift <<'SWIFT'
import Foundation

let points: [Int] = Array(0x09...0x0F) + Array(0x1C...0x20) +
    [0x85, 0xA0, 0x1680] + (0x2000...0x200B).map { $0 } +
    [0x2028, 0x2029, 0x202F, 0x205F, 0x3000]
for cp in points {
    guard let scalar = UnicodeScalar(cp) else { continue }
    let w = CharacterSet.whitespaces.contains(scalar) ? "Y" : "n"
    let wn = CharacterSet.whitespacesAndNewlines.contains(scalar) ? "Y" : "n"
    print(String(format: "%04X", cp) + "\t" + w + "\t" + wn)
}
SWIFT
swiftc -O -o /tmp/trimsets /tmp/trimsets-main.swift
/tmp/trimsets > "$FIX/trim-sets.tsv"
rm -f /tmp/trimsets /tmp/trimsets-main.swift
echo "✓ $FIX/trim-sets.tsv ($(wc -l < "$FIX/trim-sets.tsv" | tr -d ' ') символов)"
