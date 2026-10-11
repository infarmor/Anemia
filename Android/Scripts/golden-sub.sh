#!/usr/bin/env bash
#
# Эталон подписочного слоя: как Swift разбирает тело подписки (payloads.txt),
# заголовки панели (headers.txt) и решает, пора ли обновлять панель без
# пользователя (due.txt), плюс грамматику чисел Foundation (numbers.txt).
# Переводы строк в payload-фикстуре — это
# escape-последовательности \n, \r, \t (иначе кейс не влезет в одну строку).
#
#   bash Android/Scripts/golden-sub.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT/Android/core/src/test/resources/sub"
SCRATCH="${SCRATCH:-/tmp/loader-build/mac}"

cd "$ROOT"
swift build --scratch-path "$SCRATCH" --product LoaderTool 2>&1 | tail -1
TOOL="$SCRATCH/out/Products/Debug/LoaderTool"
[[ -x "$TOOL" ]] || { echo "✗ нет $TOOL" >&2; exit 1; }

"$TOOL" sub "$FIX/payloads.txt" > "$FIX/payloads.golden.txt"
"$TOOL" subinfo "$FIX/headers.txt" > "$FIX/headers.golden.txt"
echo "✓ payloads.golden.txt ($(grep -c '^===' "$FIX/payloads.golden.txt") кейсов)"
"$TOOL" subdue "$FIX/due.txt" > "$FIX/due.golden.txt"
echo "✓ due.golden.txt ($(grep -c '' "$FIX/due.golden.txt") строк, вердиктов $(grep -c 'maxAge=' "$FIX/due.golden.txt"), отказов $(grep -c '	error	' "$FIX/due.golden.txt"))"
"$TOOL" number "$FIX/numbers.txt" > "$FIX/numbers.tsv"
echo "✓ headers.golden.txt ($(grep -c '' "$FIX/headers.golden.txt") строк)"
echo "✓ numbers.tsv ($(grep -c '' "$FIX/numbers.tsv") чисел)"
