#!/usr/bin/env bash
#
# Эталон слоя состояния: как Swift читает state.json (case-файлы в
# state/cases), что из него выживает, что пишет обратно и как ведёт себя
# страховка испорченного хранилища. `LoaderTool state` прогоняет каждый файл
# через настоящий JSONDecoder и StatePersistence.load().
#
#   bash Android/Scripts/golden-state.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT/Android/core/src/test/resources/state"
SCRATCH="${SCRATCH:-/tmp/loader-build/mac}"

cd "$ROOT"
swift build --scratch-path "$SCRATCH" --product LoaderTool 2>&1 | tail -1
TOOL="$SCRATCH/out/Products/Debug/LoaderTool"
[[ -x "$TOOL" ]] || { echo "✗ нет $TOOL" >&2; exit 1; }

"$TOOL" state "$FIX/cases" > "$FIX/cases.golden.txt"
echo "✓ cases.golden.txt ($(grep -c '^===' "$FIX/cases.golden.txt") кейсов)"
