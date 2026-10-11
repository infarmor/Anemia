#!/usr/bin/env bash
#
# Эталон рейтинга и учёта трафика: `LoaderTool score` прогоняет историю проб
# через hand-built скоринг и 25 признаков kxc, `LoaderTool ledger` — сценарии
# показаний движка через TrafficLedger (тот же прогон, что считает «в сети»).
# Числа печатаются бит IEEE-754: на двух платформах десятничное представление
# одного и того же Double различается в последнем бите, а он тут и важен.
#
#   bash Android/Scripts/golden-score.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT/Android/core/src/test/resources/score"
SCRATCH="${SCRATCH:-/tmp/loader-build/mac}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT"
swift build --scratch-path "$SCRATCH" --product LoaderTool 2>&1 | tail -1
TOOL="$SCRATCH/out/Products/Debug/LoaderTool"
[[ -x "$TOOL" ]] || { echo "✗ нет $TOOL" >&2; exit 1; }

"$TOOL" score "$FIX/histories.txt" > "$FIX/histories.golden.txt"
"$TOOL" ledger "$FIX/ledger" > "$FIX/ledger.golden.txt"

# Имена признаков — не числа, их эталон даёт сам Swift-модуль: `names` живёт в
# KxcFeatures.swift, и под арабской локалью JVM дал бы «f٠٠» вместо «f00».
cat > "$WORK/main.swift" <<'SWIFT'
import Foundation
print(KxcFeatures.names.joined(separator: "\n"))
SWIFT
swiftc -O -o "$WORK/names" \
    "$ROOT/Sources/LoaderCore/KxcFeatures.swift" \
    "$ROOT/Sources/LoaderCore/ServerScoring.swift" "$WORK/main.swift"
"$WORK/names" > "$FIX/names.golden.txt"

echo "✓ histories.golden.txt ($(grep -c '' "$FIX/histories.golden.txt") историй)"
echo "✓ ledger.golden.txt ($(grep -c '^===' "$FIX/ledger.golden.txt") сценариев)"
echo "✓ names.golden.txt ($(grep -c '' "$FIX/names.golden.txt") имён)"
