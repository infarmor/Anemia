#!/usr/bin/env bash
#
# Каждый hy2-эталон из корпуса — через настоящий движок Hysteria
# (Resources/hysteria), как его собирает LoaderTool. Проверяется форма
# конфигурации, а не доступность сервера: хосты в фикстурах несуществующие,
# поэтому строка `server:` подменяется резолвящимся адресом, и в счёт идёт
# только то, что движок сказал о самом документе. Без этой подмены прогон
# «отвергает» всё подряд — так сюда и попалась первая версия скрипта, которая
# меряла DNS вместо конфига.
#
#   bash Scripts/verify-hysteria-configs.sh
#
# HYSTERIA=/path/to/hysteria — другой бинарник вместо/Resources/.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${SCRATCH:-/tmp/loader-build}"
FIX="$ROOT/Android/core/src/test/resources/hysteria"
HY="${HYSTERIA:-$ROOT/Resources/hysteria}"
[[ -x "$HY" ]] || { echo "✗ нет $HY (Scripts/fetch-extra-engines.sh hysteria)" >&2; exit 1; }
[[ -f "$FIX/links.txt" ]] || { echo "✗ нет $FIX/links.txt" >&2; exit 1; }

source "$ROOT/Scripts/toolchain-env.sh"
swift build --scratch-path "$SCRATCH" --product LoaderTool \
    ${TOOLCHAIN_SWIFT_ARGS[@]+"${TOOLCHAIN_SWIFT_ARGS[@]}"} >/dev/null 2>&1 \
    || { echo "✗ LoaderTool не собрался" >&2; exit 1; }
TOOL="$(swift build --scratch-path "$SCRATCH" --show-bin-path \
    ${TOOLCHAIN_SWIFT_ARGS[@]+"${TOOLCHAIN_SWIFT_ARGS[@]}"})/LoaderTool"
[[ -x "$TOOL" ]] || { echo "✗ нет $TOOL" >&2; exit 1; }

# Числа закреплены: «ни одного отказа» проходит и тогда, когда до движка не
# доехал ни один конфиг, и тогда, когда парсер перестал отвергать ссылки без
# пароля. 17 принимаемых + 2 законно отвергнутых на парсинге = весь hy2-угол
# корпуса (остальные строки — v1 и нерелевантные схемы).
EXPECTED_LOADED=${EXPECTED_LOADED:-17}
EXPECTED_PARSE_REFUSED=${EXPECTED_PARSE_REFUSED:-2}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
loaded=0; refused=0; parse_refused=0

while IFS= read -r line; do
    link="${line%%	*}"
    case "$link" in hy2://*) ;; *) continue ;; esac
    port="$(printf '%s' "$line" | awk -F'\t' '{print ($3==""?21180:$3)}')"
    if ! "$TOOL" hysteria-yaml "$link" --socks-port "$port" > "$WORK/raw.yaml" 2> "$WORK/err"; then
        printf '  отказ парсера  %s — %s\n' "$link" "$(head -1 "$WORK/err")"
        parse_refused=$((parse_refused + 1))
        continue
    fi
    sed 's|^server: .*|server: "example.com:443"|' "$WORK/raw.yaml" > "$WORK/config.yaml"
    ( "$HY" client -c "$WORK/config.yaml" >"$WORK/out" 2>&1 &
      child=$!; sleep 3; kill "$child" 2>/dev/null; wait "$child" 2>/dev/null )
    # Жалоба на документ против жалобы на сеть: `invalid config: server:` — это
    # DNS и диал, к форме конфига отношения не имеют.
    if grep -q "invalid config" "$WORK/out" \
        && ! grep -qE 'invalid config: server|lookup|dial|timeout' "$WORK/out"; then
        printf '  ✗ отверг движок  %s — %s\n' "$link" \
            "$(grep -m1 'invalid config' "$WORK/out" | cut -c1-140)"
        refused=$((refused + 1))
    else
        loaded=$((loaded + 1))
    fi
done < "$FIX/links.txt"

echo "— движок принял $loaded конфигов, отверг по форме $refused, парсер отверг $parse_refused"
if (( loaded != EXPECTED_LOADED || parse_refused != EXPECTED_PARSE_REFUSED )); then
    echo "✘ ожидалось $EXPECTED_LOADED принятых и $EXPECTED_PARSE_REFUSED отказов парсера — корпус или парсер изменились" >&2
    exit 1
fi
(( refused == 0 ))
