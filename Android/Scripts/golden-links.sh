#!/usr/bin/env bash
#
# Пересоздаёт эталон разбора ссылок: что Swift-парсер делает с каждой строкой
# корпуса (имена полей — те же, что сверяет Kotlin-порт).
#
#   bash Android/Scripts/golden-links.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT/Android/core/src/test/resources/links"
SCRATCH="${SCRATCH:-/tmp/loader-build/mac}"

cd "$ROOT"
swift build --scratch-path "$SCRATCH" --product LoaderTool 2>&1 | tail -1
TOOL="$SCRATCH/out/Products/Debug/LoaderTool"
[[ -x "$TOOL" ]] || { echo "✗ нет $TOOL" >&2; exit 1; }

"$TOOL" dump-links "$FIX/corpus.txt" > "$FIX/corpus.golden.txt"
echo "✓ $FIX/corpus.golden.txt ($(grep -c '^===' "$FIX/corpus.golden.txt") ссылок)"
