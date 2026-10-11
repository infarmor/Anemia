#!/usr/bin/env bash
#
# Эталон правил раздельного туннелирования: как Swift-`SplitTunnelParser`
# нормализует каждую строку каталога (или почему отвергает).
#
#   bash Android/Scripts/golden-bypass.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT/Android/core/src/test/resources/bypass"
SCRATCH="${SCRATCH:-/tmp/loader-build/mac}"

cd "$ROOT"
swift build --scratch-path "$SCRATCH" --product LoaderTool 2>&1 | tail -1
TOOL="$SCRATCH/out/Products/Debug/LoaderTool"
[[ -x "$TOOL" ]] || { echo "✗ нет $TOOL" >&2; exit 1; }

"$TOOL" split-tunnel "$FIX/lines.txt" > "$FIX/lines.golden.txt"
echo "✓ $FIX/lines.golden.txt ($(grep -c '' "$FIX/lines.golden.txt") строк)"
