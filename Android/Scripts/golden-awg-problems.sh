#!/usr/bin/env bash
#
# Пересоздаёт эталоны «что валидатор говорит про этот конфиг».
#
#   bash Android/Scripts/golden-awg-problems.sh
#
# Источник — `LoaderTool awg-uapi`, который печатает строки `problem:` и
# `warning:` из того же AmneziaWGConfigBuilder, что используют macOS и iOS.
# Тексты сообщений — часть контракта: Kotlin-порт сверяет их дословно, так что
# переформулированная строка в Swift ломает проверку, а не разъезжается молча.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT/Android/core/src/test/resources/awg"
SCRATCH="${SCRATCH:-/tmp/loader-build/mac}"

cd "$ROOT"
swift build --scratch-path "$SCRATCH" --product LoaderTool 2>&1 | tail -1
TOOL="$SCRATCH/out/Products/Debug/LoaderTool"
[[ -x "$TOOL" ]] || { echo "✗ нет $TOOL" >&2; exit 1; }

for conf in "$FIX"/*.conf; do
    name="$(basename "$conf" .conf)"
    # problem:/warning: идут в stderr; exit 3 — «есть замечания», не ошибка.
    "$TOOL" awg-uapi "$conf" 2>&1 >/dev/null | grep -E '^(problem|warning): ' > "$FIX/$name.problems.txt" || true
    echo "✓ $name.problems.txt ($(wc -l < "$FIX/$name.problems.txt" | tr -d ' ') строк)"
done
