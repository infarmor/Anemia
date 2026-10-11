#!/usr/bin/env bash
#
# Второй контур для переноса: бандл, который записал Kotlin (файл `.anemia` или
# ссылка для QR), перечитывает настоящий Swift-декодер, и результат сверяется с
# эталоном той же формы. Файловую форму Kotlin пишет байт в байт как Swift — это
# проверяет ещё test-core.sh, — а ссылку сжимает своим deflate'ом, поэтому её
# обязан принимать читатель с другой стороны. Каталоги с записями Kotlin
# оставляет test-core.sh.
#
#   bash Android/Scripts/test-core.sh && bash Android/Scripts/verify-sync.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT/Android/core/src/test/resources/sync"
WRITTEN="${WRITTEN:-/tmp/anemia-sync-kotlin}"
SCRATCH="${SCRATCH:-/tmp/loader-build/mac}"

cd "$ROOT"
[[ -d "$WRITTEN" ]] || { echo "✗ нет $WRITTEN — сначала bash Android/Scripts/test-core.sh" >&2; exit 1; }
swift build --scratch-path "$SCRATCH" --product LoaderTool 2>&1 | tail -1
TOOL="$SCRATCH/out/Products/Debug/LoaderTool"
[[ -x "$TOOL" ]] || { echo "✗ нет $TOOL" >&2; exit 1; }

# «кейс ↔ как Swift разобрал свою форму» — file-кейсы пишут файл, link-кейсы ссылку.
pairs="$(awk '
    /^=== /        { name = substr($0, 5); next }
    /^file-read\t/ && name ~ /^file-/ { print name "\t" substr($0, 11) }
    /^link-read\t/ && name ~ /^link-/ { print name "\t" substr($0, 11) }
' "$FIX/cases.golden.txt")"

fail=0
count=0
expected=$(grep -c . <<<"$pairs")
while IFS=$'\t' read -r name want; do
    [[ -n "${name:-}" ]] || continue
    file="$WRITTEN/${name}.anemia"
    [[ -f "$file" ]] || file="$WRITTEN/${name}.txt"
    if [[ ! -f "$file" ]]; then
        echo "✗ $name: Kotlin не записал ни .anemia, ни ссылку"
        fail=$((fail + 1))
        continue
    fi
    got="$("$TOOL" sync-read "$file" | cut -f3-)"
    count=$((count + 1))
    if [[ "$got" != "$want" ]]; then
        echo "✗ $name: Swift прочитал запись Kotlin иначе"
        echo "   ждали $want"
        echo "   получил $got"
        fail=$((fail + 1))
    fi
done <<< "$pairs"

if (( expected == 0 || count != expected )); then
    echo "✗ сверено $count из $expected бандлов — часть кейсов не дошла до Swift" >&2
    exit 1
fi

rm -rf "$WRITTEN"
echo "✓ бандлов Kotlin перечитано Swift'ом: $count, расхождений: $fail"
[[ $fail -eq 0 ]]
