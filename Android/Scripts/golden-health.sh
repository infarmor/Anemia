#!/usr/bin/env bash
#
# Эталон правил здоровья туннеля: `LoaderTool health` прогоняет `health/cases.txt`
# через тот же `TunnelHealth`, который теперь вызывает iOS-расширение, а Kotlin
# сверяется с ответом (`test-core.sh`, проверка «правила здоровья туннеля»).
#
#   bash Android/Scripts/golden-health.sh
#   bash Android/Scripts/golden-health.sh -f   # переписать фикстуру скриптом
#
# Генерация дважды и сравнение md5: эталон, который меняется от запуска к запуску,
# не доказывает ничего.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT/Android/core/src/test/resources/health"
SCRATCH="${SCRATCH:-/tmp/loader-build/mac}"

cd "$ROOT"
if [[ "${1:-}" == "-f" ]]; then
    python3 Android/Scripts/make-health-fixture.py
fi

swift build --scratch-path "$SCRATCH" --product LoaderTool 2>&1 | tail -1
TOOL="$SCRATCH/out/Products/Debug/LoaderTool"
[[ -x "$TOOL" ]] || { echo "✗ нет $TOOL" >&2; exit 1; }
[[ -f "$FIX/cases.txt" ]] || { echo "✗ нет $FIX/cases.txt" >&2; exit 1; }

# Две фикстуры одного слоя: вердикт проверки и расписание (когда её вообще
# запускать и когда её ответ ещё чему-то верится).
"$TOOL" health "$FIX/cases.txt" > "$FIX/cases.golden.txt"
first="$(md5 -q "$FIX/cases.golden.txt")"
second="$("$TOOL" health "$FIX/cases.txt" | md5 -q)"
[[ "$first" == "$second" ]] || { echo "✗ эталон не детерминирован" >&2; exit 1; }

cases="$(grep -c '' "$FIX/cases.txt")"
rows="$(grep -c '' "$FIX/cases.golden.txt")"
verdicts="$(grep -c 'outcome=' "$FIX/cases.golden.txt" || true)"
echo "✓ health/cases.golden.txt: кейсов $cases, строк $rows, вердиктов $verdicts, отказов $((rows - verdicts))"
if [[ "$cases" != "$rows" || "$verdicts" -lt 20 ]]; then
    echo "✗ кейсов $cases, вердиктов $verdicts: фикстура обрезана или развалилась в отказы" >&2
    exit 1
fi

"$TOOL" healthdue "$FIX/run.txt" > "$FIX/run.golden.txt"
rfirst="$(md5 -q "$FIX/run.golden.txt")"
rsecond="$("$TOOL" healthdue "$FIX/run.txt" | md5 -q)"
[[ "$rfirst" == "$rsecond" ]] || { echo "✗ эталон расписания не детерминирован" >&2; exit 1; }
rcases="$(grep -c '' "$FIX/run.txt")"
rrows="$(grep -c '' "$FIX/run.golden.txt")"
rverdicts="$(grep -c 'due=' "$FIX/run.golden.txt" || true)"
echo "✓ health/run.golden.txt: кейсов $rcases, строк $rrows, вердиктов $rverdicts, отказов $((rrows - rverdicts))"
if [[ "$rcases" != "$rrows" || "$rverdicts" -lt 20 ]]; then
    echo "✗ кейсов $rcases, вердиктов $rverdicts: фикстура обрезана" >&2
    exit 1
fi
