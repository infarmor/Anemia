#!/usr/bin/env bash
#
# Эталон «последних слов движка»: `LoaderTool enginelog` прогоняет
# `engine/cases.txt` через тот же `EngineLog`, что теперь вызывает Android в
# `Engine.startXray`/`startAwg`, и Kotlin сверяется с ответом (проверка
# «последние слова движка совпадают со Swift»).
#
# Фикстура — настоящие тексты xray 26.3.27, снятые с бинарника из Resources/
# (bind на привилегированный порт, отказ на разборе конфига, removed feature).
# Придуманные строки тут дешевле настоящих: формат цепочки `a > b > c` и префикс
# Go-пакета — то, что сочинить нельзя.
#
#   bash Android/Scripts/golden-engine.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT/Android/core/src/test/resources/engine"
SCRATCH="${SCRATCH:-/tmp/loader-build/mac}"

cd "$ROOT"
swift build --scratch-path "$SCRATCH" --product LoaderTool 2>&1 | tail -1
TOOL="$SCRATCH/out/Products/Debug/LoaderTool"
[[ -x "$TOOL" ]] || { echo "✗ нет $TOOL" >&2; exit 1; }
[[ -f "$FIX/cases.txt" ]] || { echo "✗ нет $FIX/cases.txt" >&2; exit 1; }

"$TOOL" enginelog "$FIX/cases.txt" > "$FIX/cases.golden.txt"
first="$(md5 -q "$FIX/cases.golden.txt")"
second="$("$TOOL" enginelog "$FIX/cases.txt" | md5 -q)"
[[ "$first" == "$second" ]] || { echo "✗ эталон не детерминирован" >&2; exit 1; }

cases="$(grep -c '' "$FIX/cases.txt")"
rows="$(grep -c '' "$FIX/cases.golden.txt")"
verdicts="$(grep -c 'reason=' "$FIX/cases.golden.txt" || true)"
echo "✓ engine/cases.golden.txt: кейсов $cases, строк $rows, вердиктов $verdicts, отказов $((rows - verdicts))"
if [[ "$cases" != "$rows" || "$verdicts" -lt 15 ]]; then
    echo "✗ кейсов $cases, вердиктов $verdicts: фикстура обрезана или развалилась в отказы" >&2
    exit 1
fi
