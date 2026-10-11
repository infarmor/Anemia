#!/usr/bin/env bash
#
# Второй контур для состояния: байты, которые написал Kotlin, перечитывает
# настоящий Swift-декодер (`LoaderTool state-read`), и результат сверяется с тем
# же эталоном, что и сам Kotlin. Так проверяется не «Kotlin понял Kotlin», а то,
# что файл, сохранённый приложением на Android, Mac и iPhone прочитают без
# потерь. Каталог с записями Kotlin оставляет test-core.sh.
#
#   bash Android/Scripts/test-core.sh && bash Android/Scripts/verify-state.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT/Android/core/src/test/resources/state"
WRITTEN="${WRITTEN:-/tmp/anemia-state-kotlin}"
SCRATCH="${SCRATCH:-/tmp/loader-build/mac}"

cd "$ROOT"
[[ -d "$WRITTEN" ]] || { echo "✗ нет $WRITTEN — сначала bash Android/Scripts/test-core.sh" >&2; exit 1; }
swift build --scratch-path "$SCRATCH" --product LoaderTool 2>&1 | tail -1
TOOL="$SCRATCH/out/Products/Debug/LoaderTool"
[[ -x "$TOOL" ]] || { echo "✗ нет $TOOL" >&2; exit 1; }

# Пары «кейс ↔ эталонный JSON» из golden-файла (обе строки одинаковы, когда
# кейс читается; для битых эталон — строка loaded).
pairs="$(awk '
    /^=== /   { name = substr($0, 5) }
    /^decode\t/ && $0 != "decode\tthrow" { print name "\t" substr($0, 8) }
' "$FIX/cases.golden.txt")"

fail=0
count=0
expected=$(grep -c . <<<"$pairs")
while IFS=$'\t' read -r name want; do
    [[ -n "${name:-}" ]] || continue
    # Пропустить кейс — значит молча потерять половину утверждения «Swift
    # читает то, что записал Kotlin»: отсутствие файла теперь красное.
    if [[ ! -f "$WRITTEN/${name}.json" ]]; then
        echo "✗ $name: Kotlin не записал ${name}.json"
        fail=$((fail + 1))
        continue
    fi
    got="$("$TOOL" state-read "$WRITTEN/${name}.json" | cut -f2-)"
    count=$((count + 1))
    if [[ "$got" != "$want" ]]; then
        echo "✗ $name: Swift прочитал запись Kotlin иначе"
        echo "   ждали $want"
        echo "   получил $got"
        fail=$((fail + 1))
    fi
done <<< "$pairs"

if (( expected == 0 || count != expected )); then
    echo "✗ сверено $count из $expected записей — часть кейсов не дошла до Swift" >&2
    rm -rf "$WRITTEN"
    exit 1
fi

rm -rf "$WRITTEN"
echo "✓ сверено записей Kotlin через Swift-декодер: $count, расхождений: $fail"
[[ $fail -eq 0 ]]
