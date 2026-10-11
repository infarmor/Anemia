#!/usr/bin/env bash
#
# Наблюдатель за туннелем: показывает, что система действительно видит VPN,
# а не то, что приложение о себе сообщает. Подключение и отключение — руками
# (на эмуляторе: `adb shell input tap …`), скрипт только снимает состояние.
#
#   bash Android/Scripts/verify-tunnel.sh ['vless://…@1.2.3.4:443?type=tcp']
#
# Нужен устройство или эмулятор, видимый adb. Выход — 0, если за время работы
# был наблюдаем поднятый туннель (интерфейс + маршруты по умолчанию), и 1,
# если нет: «приложение запущено» ничего не доказывает.
set -uo pipefail

# Каждый ✗ должен стоить прогону нуля: иначе «туннель поднимался» засчитывается,
# когда маршрутов по умолчанию не оказалось вовсе.
fail=0

SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$SDK/platform-tools/adb"
LINK="${1:-}"
SECONDS_TOTAL="${SECONDS_TOTAL:-180}"

command -v "$ADB" >/dev/null || { echo "✗ нет $ADB" >&2; exit 1; }
"$ADB" get-state >/dev/null 2>&1 || { echo "✗ устройство не подключено" >&2; exit 1; }

if [[ -n "$LINK" ]]; then
    # На устройстве аргумент бережём в одинарных кавычках: `&`, `#` и пробелы
    # в ссылке иначе разбирает shell'ом телефона (проверено: `&` резал ссылку
    # посередине, и тест подключался не туда).
    quoted="'${LINK//\'/\'\\'\'}'"
    "$ADB" shell "am start -n app.anemia/.ui.MainActivity --es link $quoted" >/dev/null
    echo "→ экран Anemia открыт, ссылка передана"
else
    echo "→ ссылка не передана: вставьте её в поле сами"
fi

deadline=$(( SECONDS + SECONDS_TOTAL ))
seen_up=0
defaults_seen=0
rules_seen=0
while (( SECONDS < deadline )); do
    ifaces=$("$ADB" shell ip -brief addr 2>/dev/null | tr -d '\r' | grep -E '^tun[0-9]+ ' || true)
    routes=$("$ADB" shell ip route show table all 2>/dev/null | tr -d '\r' | grep -c 'dev tun' || true)
    defaults=$("$ADB" shell ip route show table all 2>/dev/null | tr -d '\r' | grep -c '^default dev tun' || true)
    rules=$("$ADB" shell ip rule show 2>/dev/null | tr -d '\r' | grep -c 'lookup tun' || true)
    status=$("$ADB" shell dumpsys notification --noredact 2>/dev/null | tr -d '\r' \
        | grep -m1 -oE '(xray|awg) · [^"]*' || true)
    ours=$("$ADB" shell "pidof app.anemia:vpn" 2>/dev/null | tr -d '\r')

    if [[ -n "$ifaces" ]]; then
        seen_up=1
        (( defaults_seen < defaults )) && defaults_seen=$defaults
        (( rules_seen < rules )) && rules_seen=$rules
        echo "▲ ${ifaces//$'\n'/; }"
        echo "  маршрутов dev tun: $routes (из них default: $defaults), правил lookup tun: $rules"
        echo "  статус сервиса: ${status:-нет уведомления}"
        # Наш UID должен быть вырезан из туннеля: иначе сокет движка уедет
        # в туннель, который он же поднимает.
        if [[ -n "$ours" && -n "$rules" ]]; then
            uid=$("$ADB" shell "stat -c %u /proc/$ours" 2>/dev/null | tr -d '\r')
            ranges=$("$ADB" shell ip rule show 2>/dev/null | tr -d '\r' | grep 'lookup tun' \
                | grep -oE 'uidrange [0-9]+-[0-9]+' | sed 's/uidrange //' | sort -u)
            covered=0
            while read -r range; do
                [[ "$range" == *-* ]] || continue
                lo=${range%-*}; hi=${range#*-}
                if [[ "$uid" =~ ^[0-9]+$ ]] && (( uid >= lo && uid <= hi )); then covered=1; fi
            done <<< "$ranges"
            if (( covered )); then
                echo "  ✗ UID $uid внутри туннеля: сокет движка поедет в него же"
                fail=1
            elif [[ "$uid" =~ ^[0-9]+$ ]]; then
                echo "  UID $uid вне туннеля ✓ (addDisallowedApplication работает)"
            else
                echo "  ✗ не удалось прочитать UID процесса $ours"
                fail=1
            fi
        fi
    else
        echo "· туннеля нет; процесс :vpn: ${ours:-не запущен}; статус: ${status:-—}"
    fi
    sleep 3
done

# Поднявшимся туннель считается, только если у него были маршруты по умолчанию:
# интерфейс без них — это ровно тот «живой с виду мёртвый» случай, который
# чинил `waitUntil`.
if (( seen_up && defaults_seen > 0 && rules_seen > 0 && fail == 0 )); then
    echo "✓ туннель поднимался: default-маршрутов $defaults_seen, правил $rules_seen"
else
    echo "✘ туннель не засчитан: поднимался=$seen_up default=$defaults_seen правил=$rules_seen ошибок=$fail" >&2
    exit 1
fi
