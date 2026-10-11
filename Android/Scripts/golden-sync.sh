#!/usr/bin/env bash
#
# Эталон sync-слоя: как Swift читает бандл (`.anemia`-файл и ссылку для QR),
# что пишет в обеих формах и что делает слияние с уже сохранённым состоянием.
# Кейсы — sync/cases/*.json, где каждый описывает одно действие (`kind`).
#
#   bash Android/Scripts/golden-sync.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT/Android/core/src/test/resources/sync"
SCRATCH="${SCRATCH:-/tmp/loader-build/mac}"

cd "$ROOT"
swift build --scratch-path "$SCRATCH" --product LoaderTool 2>&1 | tail -1
TOOL="$SCRATCH/out/Products/Debug/LoaderTool"
[[ -x "$TOOL" ]] || { echo "✗ нет $TOOL" >&2; exit 1; }

"$TOOL" sync "$FIX/cases" > "$FIX/cases.golden.txt"
"$TOOL" looks "$FIX/looks/cases.txt" > "$FIX/looks/cases.golden.txt"
"$TOOL" carry "$FIX/carry/cases.txt" > "$FIX/carry/cases.golden.txt"
echo "✓ cases.golden.txt ($(grep -c '^===' "$FIX/cases.golden.txt") кейсов)"
echo "✓ looks: $(grep -c '' "$FIX/looks/cases.golden.txt") строк, carry: $(grep -c '' "$FIX/carry/cases.golden.txt")"
