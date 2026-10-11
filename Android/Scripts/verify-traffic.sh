#!/usr/bin/env bash
#
# Третий контур для трафика: документ, который записал Kotlin, перечитывает
# настоящий Swift-декодер (`LoaderTool ledger-read`) и переписывает обратно.
# Результат сверяется с тем же документом, который пишет Swift. Так проверяется
# не «Kotlin понял Kotlin», а то, что файл Android'а Mac и iPhone прочтут без
# потерь — включая сдвиг reference date (даты в этом документе не от эпохи Unix)
# и плоский массив «ключ, значение» для словаря с UUID-ключами.
#
#   bash Android/Scripts/test-core.sh && bash Android/Scripts/verify-traffic.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT/Android/core/src/test/resources/score"
WRITTEN="${WRITTEN_TRAFFIC:-/tmp/anemia-traffic-kotlin}"
SCRATCH="${SCRATCH:-/tmp/loader-build/mac}"

cd "$ROOT"
[[ -d "$WRITTEN" ]] || { echo "✗ нет $WRITTEN — сначала bash Android/Scripts/test-core.sh" >&2; exit 1; }
swift build --scratch-path "$SCRATCH" --product LoaderTool 2>&1 | tail -1
TOOL="$SCRATCH/out/Products/Debug/LoaderTool"
[[ -x "$TOOL" ]] || { echo "✗ нет $TOOL" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Пары «кейс ↔ документ Swift» из эталона.
pairs="$(awk '
    /^=== /    { name = substr($0, 5) }
    /^json\t/  { print name "\t" substr($0, 6) }
' "$FIX/ledger.golden.txt")"

fail=0
count=0
expected=$(grep -c . <<<"$pairs")
while IFS=$'\t' read -r name doc; do
    [[ -n "${name:-}" ]] || continue
    if [[ ! -f "$WRITTEN/${name}.json" ]]; then
        echo "✗ $name: Kotlin не записал ${name}.json"
        fail=$((fail + 1))
        continue
    fi
    printf '%s' "$doc" > "$WORK/${name}-swift.json"
    # Одно обращение к инструменту: он печатает по строке на файл, поля
    # разделяет табом (в имени сервера бывают пробелы — `cut`, а не `read`).
    both="$("$TOOL" ledger-read "$WORK/${name}-swift.json" "$WRITTEN/${name}.json")"
    fromSwift="$(printf '%s\n' "$both" | head -1 | cut -f2-)"
    fromKotlin="$(printf '%s\n' "$both" | tail -1 | cut -f2-)"
    count=$((count + 1))
    if [[ "$fromKotlin" == "throw" || "$fromSwift" == "throw" ]]; then
        echo "✗ $name: Swift не прочитал документ (kotlin: $fromKotlin, swift: $fromSwift)"
        fail=$((fail + 1))
        continue
    fi
    if [[ "$fromKotlin" != "$fromSwift" ]]; then
        echo "✗ $name: Swift прочитал запись Kotlin иначе"
        echo "   ждали $fromSwift"
        echo "   получил $fromKotlin"
        fail=$((fail + 1))
    fi
done <<< "$pairs"

# Пустая выборка — это не «расхождений нет»: кейсы могли просто не дойти.
if (( expected == 0 || count != expected )); then
    echo "✗ сверено $count из $expected документов — часть кейсов не дошла до Swift" >&2
    exit 1
fi

echo "✓ сверено записей Kotlin через Swift-декодер: $count, расхождений: $fail"
[[ $fail -eq 0 ]]
