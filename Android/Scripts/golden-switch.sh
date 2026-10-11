#!/usr/bin/env bash
#
# Эталон решения «уводить ли туннель на другой сервер»: `LoaderTool switchdue`
# прогоняет фикстуру `switch/due.txt` через тот же `AutoSwitchPolicy`, который
# вызывает iOS из `AutoSwitch.evaluate()`, и Kotlin сверяется с ответом.
#
#   bash Android/Scripts/golden-switch.sh
#   bash Android/Scripts/golden-switch.sh -f   # переписать фикстуру скриптом
#
# GENERATOR=... : собрать фикстуру заново (Android/Scripts/make-switch-fixture.py).
# Генерация — дважды, и md5 сравнивается: золотой, который меняется от запуска к
# запуску, не доказывает ничего (на этом уже обжигались ряде синхронизации).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT/Android/core/src/test/resources/switch"
SCRATCH="${SCRATCH:-/tmp/loader-build/mac}"

cd "$ROOT"
if [[ "${1:-}" == "-f" ]]; then
    python3 Android/Scripts/make-switch-fixture.py
fi

swift build --scratch-path "$SCRATCH" --product LoaderTool 2>&1 | tail -1
TOOL="$SCRATCH/out/Products/Debug/LoaderTool"
[[ -x "$TOOL" ]] || { echo "✗ нет $TOOL" >&2; exit 1; }
[[ -f "$FIX/due.txt" ]] || { echo "✗ нет $FIX/due.txt" >&2; exit 1; }

# Две фикстуры одного решения: «пора ли уводить» и «сколько раз уже уводили».
"$TOOL" switchdue "$FIX/due.txt" > "$FIX/due.golden.txt"
first="$(md5 -q "$FIX/due.golden.txt")"
second="$("$TOOL" switchdue "$FIX/due.txt" | md5 -q)"
[[ "$first" == "$second" ]] || { echo "✗ эталон не детерминирован" >&2; exit 1; }

cases="$(grep -c '' "$FIX/due.txt")"
rows="$(grep -c '' "$FIX/due.golden.txt")"
verdicts="$(grep -c 'verdict=' "$FIX/due.golden.txt" || true)"
errors="$((rows - verdicts))"
echo "✓ switch/due.golden.txt: кейсов $cases, строк $rows, вердиктов $verdicts, отказов $errors"

"$TOOL" budget "$FIX/budget.txt" > "$FIX/budget.golden.txt"
bfirst="$(md5 -q "$FIX/budget.golden.txt")"
bsecond="$("$TOOL" budget "$FIX/budget.txt" | md5 -q)"
[[ "$bfirst" == "$bsecond" ]] || { echo "✗ эталон бюджета не детерминирован" >&2; exit 1; }
bcases="$(grep -c '' "$FIX/budget.txt")"
brows="$(grep -c '' "$FIX/budget.golden.txt")"
bverdicts="$(grep -c 'marks=' "$FIX/budget.golden.txt" || true)"
echo "✓ switch/budget.golden.txt: кейсов $bcases, строк $brows, вердиктов $bverdicts, отказов $((brows - bverdicts))"
if [[ "$bcases" != "$brows" || "$bverdicts" -lt 15 ]]; then
    echo "✗ кейсов $bcases, вердиктов $bverdicts" >&2
    exit 1
fi
if [[ "$cases" != "$rows" || "$verdicts" -lt 25 ]]; then
    echo "✗ кейсов $cases, а вердиктов $verdicts: фикстура молча проглотчена или обрезана" >&2
    exit 1
fi
