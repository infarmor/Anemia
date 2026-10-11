#!/usr/bin/env bash
#
# Эталон проверок на утечки и политики проб: `LoaderTool leak` прогоняет ответы
# ip.sb, Cloudflare и bash.ws через парсеры Swift и спрашивает `findings`, что с
# этим показать пользователю; `LoaderTool probe` — чистую половину зонда (что
# стучаться и когда сдаваться на мёртвом сервере). Сетевых вызовов тут нет
# намеренно: сверяется только то, что обязано читаться одинаково на трёх
# платформах.
#
#   bash Android/Scripts/golden-leak.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT/Android/core/src/test/resources"
SCRATCH="${SCRATCH:-/tmp/loader-build/mac}"

cd "$ROOT"
swift build --scratch-path "$SCRATCH" --product LoaderTool 2>&1 | tail -1
TOOL="$SCRATCH/out/Products/Debug/LoaderTool"
[[ -x "$TOOL" ]] || { echo "✗ нет $TOOL" >&2; exit 1; }

"$TOOL" leak "$FIX/leak/answers.txt" > "$FIX/leak/answers.golden.txt"
"$TOOL" probe "$FIX/probe/cases.txt" > "$FIX/probe/cases.golden.txt"
"$TOOL" hysteria "$FIX/hysteria/links.txt" > "$FIX/hysteria/links.golden.txt"
"$TOOL" stats "$FIX/stats/wire.txt" > "$FIX/stats/wire.golden.txt"
"$TOOL" mask "$FIX/mask/cases.txt" > "$FIX/mask/cases.golden.txt"
echo "✓ leak: $(grep -c '' "$FIX/leak/answers.golden.txt") ответов"
echo "✓ probe: $(grep -c '' "$FIX/probe/cases.golden.txt") случаев"
echo "✓ hysteria: $(grep -c '^===' "$FIX/hysteria/links.golden.txt") ссылок"
echo "✓ stats: $(grep -c '' "$FIX/stats/wire.golden.txt") случаев"
echo "✓ mask: $(grep -c '' "$FIX/mask/cases.golden.txt") случаев"
