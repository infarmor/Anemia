#!/usr/bin/env bash
#
# Второй контур для hysteria: каждый YAML, который собрал C#, отдаётся настоящему
# бинарю `hysteria client -c …`. Паритет с Swift (ParityHysteriaTests) доказывает
# только согласие байтов — а байты могут быть согласованно неверными: в 2026-09
# так уже было с конфигом VLESS в старой короткой форме, который xray отвергал,
# хотя Kotlin и Swift печатали его одинаково.
#
#   bash windows-version-alpha/Scripts/verify-hysteria.sh
#
# Честная граница этого контура, измеренная на бинаре (Resources/hysteria,
# 2026-09-27): клиент ругается ТОЛЬКО на синтаксис YAML —
#   «failed to read client config / While parsing config: …».
# Неизвестное поле (`unknown_field: 7`) и поле неверной формы (`tls: 5` вместо
# блока) он молча принимает и молча игнорирует: опции TLS просто перестают
# действовать. Значит опечатка в имени поля здесь не ловится — за неё отвечают
# побайтовый эталон (ParityHysteriaTests) и проверки имён полей в тестах.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HYSTERIA="${HYSTERIA:-$ROOT/Resources/hysteria}"
FIX="$ROOT/Android/core/src/test/resources/hysteria/links.txt"
OUT_DIR="${OUT_DIR:-/tmp/win-hysteria}"

source "$(dirname "$0")/dotnet-env.sh"

[[ -x "$HYSTERIA" ]] || { echo "✗ нет $HYSTERIA (он в Resources/, тот же, что для macOS)" >&2; exit 1; }
[[ -f "$FIX" ]] || { echo "✗ нет $FIX" >&2; exit 1; }

BIN_DIR="${BIN_DIR:-/tmp/win-tool}"
echo "→ собирает AnemiaTool"
rm -rf "$BIN_DIR"
"$DOTNET_ROOT/dotnet" build "$ROOT/windows-version-alpha/tools/AnemiaTool/AnemiaTool.csproj" \
    -v q --nologo --no-incremental -o "$BIN_DIR" >&2
TOOL=("$DOTNET_ROOT/dotnet" "$BIN_DIR/AnemiaTool.dll")

rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"
accepted=0; refused=0; skipped=0; index=0
while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    index=$((index + 1))
    # Колонки: `ссылка [порт]` или `server <json> <порт>`. JSON-форма задаёт
    # сервер напрямую — только так проверяются формы, которые ссылка описать не
    # может (IPv6 без скобок, hopping не покрывающий порт).
    if [[ "${row%%$'\t'*}" == "server" ]]; then
        link="$(printf '%s' "$row" | cut -f2)"
        port="$(printf '%s' "$row" | cut -f3)"
    else
        link="${row%%$'\t'*}"
        port="$(printf '%s' "$row" | cut -f2)"
    fi
    [[ -n "$port" ]] || port=21180

    out="$("${TOOL[@]}" hysteria-yaml "$link" --socks-port "$port" 2>/dev/null || true)"
    if [[ "$out" == error* || -z "$out" ]]; then
        skipped=$((skipped + 1))
        continue
    fi
    file="$OUT_DIR/$index.yaml"
    # Адрес заменяется на несуществующий порт на localhost: разбор конфига
    # происходит до сети, а соединение либо не проходит, либо ловит таймаут —
    # и то, и другое означает «YAML принят».
    printf '%s' "$out" | sed -E 's|^(server: ").*(")$|\1127.0.0.1:44443\2|' > "$file"
    # 6 с: клиент обязан успеть разобрать конфиг и уйти в dial/timeout.
    result="$(perl -e 'alarm 6; exec @ARGV or die' "$HYSTERIA" client -c "$file" 2>&1 || true)"
    if printf '%s' "$result" | grep -qiE 'failed to read client config|While parsing config|cannot unmarshal'; then
        refused=$((refused + 1))
        echo "✘ бинарь отверг кейс $index: $(printf '%s' "$result" | grep -m1 -iE 'config|yaml|invalid|unknown' | cut -c1-180)"
    else
        accepted=$((accepted + 1))
    fi
done < "$FIX"

total=$((accepted + refused))
echo "— hysteria принял $accepted, отверг $refused (ссылок без YAML: $skipped, всего строк $index)"
if [[ $accepted -eq 0 ]]; then
    echo "✘ ни один конфиг не дошёл до бинаря" >&2
    exit 1
fi
[[ $refused -eq 0 ]]
