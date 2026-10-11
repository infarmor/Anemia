#!/usr/bin/env bash
#
# Пересоздаёт эталон конфига движка: что Swift-`XrayConfigBuilder` выдаёт в
# форме packet-tunnel (как iOS сегодня и Android следом) для каждого случая из
# cases.tsv — строка: id, ссылка, дополнительные аргументы emit-tun.
#
# Отказ разбирается так же: текст ошибки Swift — тоже эталон.
#
#   bash Android/Scripts/golden-xray.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT/Android/core/src/test/resources/xray"
SCRATCH="${SCRATCH:-/tmp/loader-build/mac}"

cd "$ROOT"
swift build --scratch-path "$SCRATCH" --product LoaderTool 2>&1 | tail -1
TOOL="$SCRATCH/out/Products/Debug/LoaderTool"
[[ -x "$TOOL" ]] || { echo "✗ нет $TOOL" >&2; exit 1; }

rm -f "$FIX"/*.json "$FIX"/*.err
count=0
while IFS=$'\t' read -r id link rest; do
    [[ -n "${id:-}" && -n "${link:-}" ]] || continue
    # rest — это несколько аргументов, разделённых пробелом, намеренно без кавычек.
    code=0
    out="$("$TOOL" emit-tun "$link" ${rest:-} 2>&1)" || code=$?
    if [[ $code -eq 0 ]]; then
        printf '%s\n' "$out" > "$FIX/$id.json"
        echo "✓ $id.json ($(wc -l < "$FIX/$id.json" | tr -d ' ') строк)"
    else
        printf '%s\n' "$(printf '%s' "$out" | tail -1)" > "$FIX/$id.err"
        echo "✓ $id.err — $(cat "$FIX/$id.err")"
    fi
    count=$((count + 1))
done < <(sed -e 's/[[:space:]]*$//' "$FIX/cases.tsv" | grep -v '^#' | grep -v '^$')
echo "— случаев: $count"
