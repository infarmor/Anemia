#!/usr/bin/env bash
#
# Пересоздаёт эталоны UAPI-скриптов из настоящего Swift-кода.
#
#   bash Android/Scripts/golden-awg.sh
#
# Эталон пишет `LoaderTool awg-uapi` — тот же AmneziaWGConfigBuilder, которым
# пользуются macOS и iOS. После любой правки в Sources/LoaderCore/AmneziaWG.swift
# или в парсере конфигов нужно перегенерировать их и прогнать test-core.sh:
# молчаливый drift между платформами — ровно то, из-за чего AWG-конфиг
# «работает на Mac и не работает на телефоне».
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURES="$ROOT/Android/core/src/test/resources/awg"
SCRATCH="${SCRATCH:-/tmp/loader-build/mac}"

cd "$ROOT"
swift build --scratch-path "$SCRATCH" --product LoaderTool 2>&1 | tail -1
TOOL="$SCRATCH/out/Products/Debug/LoaderTool"
[[ -x "$TOOL" ]] || { echo "✗ нет $TOOL" >&2; exit 1; }

for conf in "$FIXTURES"/*.conf; do
    name="$(basename "$conf" .conf)"
    # 3 = «есть замечания валидатора», это не ошибка сборки.
    code=0
    "$TOOL" awg-uapi "$conf" > "$FIXTURES/$name.uapi" || code=$?
    [[ $code -eq 0 || $code -eq 3 ]] || { echo "✗ $name: код $code" >&2; exit 1; }
    echo "✓ $name.uapi ($(wc -l < "$FIXTURES/$name.uapi" | tr -d ' ') строк)"
done
# Тот же скрипт, но для сервера из подписки: `ProxyServer`, а не разобранный
# conf-файл. До этого золотой сверкой был covered только conf-путь, и порт
# мог не уметь собирать UAPI для ссылки вообще (он и не умел).
echo "→ ссылки"
out="$FIXTURES/links.uapi"
: > "$out"
while IFS=$'\t' read -r label link; do
    [[ -n "${label:-}" ]] || continue
    stdout="$(mktemp)"; stderr="$(mktemp)"
    code=0
    "$TOOL" awg-uapi "$link" >"$stdout" 2>"$stderr" || code=$?
    {
        echo "=== $label"
        if [[ $code -eq 1 ]]; then
            grep -m1 '^error: ' "$stderr" || echo "error: (без текста)"
        else
            cat "$stdout"
        fi
    } >> "$out"
    rm -f "$stdout" "$stderr"
done < "$FIXTURES/links.txt"
echo "✓ links.uapi ($(grep -c '^=== ' "$out") ссылок)"

