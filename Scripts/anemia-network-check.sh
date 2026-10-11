#!/bin/bash
#
# Anemia network check — читает состояние сети и говорит, остались ли за
# прошлой сессии Anemia/Loader следы, которые перекрывают интернет. НИЧЕГО
# не меняет: ни маршрутов, ни DNS, ни pf, ни процессов. Именно поэтому его
# можно запустить сразу после «отключить» и увидеть, что раскрутка
# недоработала, а не чинить вслепую.
#
#   bash Scripts/anemia-network-check.sh          # что видно без root
#   sudo bash Scripts/anemia-network-check.sh     # плюс журнал хелпера и pf
#
# Выход: 0 — чисто, 1 — есть за нами, 2 — не удалось прочесть достаточно,
# чтобы утверждать любое из двух (молча «зелёным» такой прогон не бывает).
#
# Dependency-free: bash 3.2, networksetup, netstat, ifconfig, plutil.
set -u

NS=/usr/sbin/networksetup
STATE=/var/db/Loader
JOURNAL="$STATE/network-journal.json"
ANCHOR=com.apple/000.AnemiaKillSwitch
JOURNAL_READABLE=0
SUDO_NEEDED=1

say() { echo "• $*"; PROBLEM=1; }

# Диапазоны резолверов, которые принадлежат туннелю Anemia: нынешний, второй
# (AWG) и legacy 198.18 — тот же набор, что у reset-скрипта и у `isDeadDNSPin`.
is_tunnel_resolver() {
    case "$1" in
        172.28.0.*|172.29.0.*|198.18.0.*) return 0 ;;
        *) return 1 ;;
    esac
}

live_ipv4() { ifconfig -a 2>/dev/null | awk '/inet /{print $2}' | tr '\n' ' '; }
LIVE="$(live_ipv4)"
held_locally() {
    target="$1"; prefix="${target%.*}"
    for a in $LIVE; do [ "${a%.*}" = "$prefix" ] && return 0; done
    return 1
}
iface_exists() { ifconfig "$1" >/dev/null 2>&1; }

PROBLEM=0
echo "— состояние сети после сессий Anemia (только чтение)"

# 1. Маршруты «весь интернет», ведущие на utun, которого больше нет. Ядро
#    обычно снимает их вместе с интерфейсом, но `route change` до правки
#    add-first писал в real default — и такой след переживает смерть utun.
for line in $(/usr/sbin/netstat -rn -f inet 2>/dev/null | awk '$1=="default"||$1=="0/1"||$1=="0.0.0.0/1"||$1=="128.0.0.0/1"||$1=="128/1"{print $NF}'); do
    case "$line" in
        utun*)
            if ! iface_exists "$line"; then
                say "маршрут по умолчанию/сплит висит на мёртвом $line"
            fi ;;
    esac
done
/usr/sbin/netstat -rn -f inet 2>/dev/null \
    | awk '$1=="default"||$1=="0/1"||$1=="0.0.0.0/1"||$1=="128.0.0.0/1"{print "  строка маршрута: "$0}'

# 2. DNS, прибитый к адресу туннеля, которого уже никто не держит.
# Список сервисов — построчно, с сохранением пробелов в именах
# («USB 10/100/1000 LAN» — одно имя, а не три). Звёздочка перед именем
# означает отключённый сервис: читаем и его, если он у нас в журнале, —
# но пишет хелпер только сервисы с непустым Device.
names_to_lines() {
    $NS -listnetworkserviceorder 2>/dev/null | awk '
        /^[[:space:]]*\*?\([0-9]+\)[[:space:]]/ {
            sub(/^[[:space:]]*\*?\([0-9]+\)[[:space:]]*/, "")
            print
        }'
}
if [ -z "$(names_to_lines)" ]; then echo "!!  не удалось перечислить сетевые сервисы"; exit 2; fi
while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    cur="$($NS -getdnsservers "$svc" 2>/dev/null | tr '\n' ' ')"
    ours=0
    for ip in $cur; do is_tunnel_resolver "$ip" && ours=1; done
    [ "$ours" = 1 ] || continue
    dead=1
    for ip in $cur; do is_tunnel_resolver "$ip" || dead=0; done
    for ip in $cur; do held_locally "$ip" && dead=0; done
    if [ "$dead" = 1 ]; then
        say "DNS «$svc» = $cur — резолвер внутри мёртвого туннеля, сайты грузиться не будут"
    else
        echo "  DNS «$svc» = $cur (туннель жив, это штатно)"
    fi
done <<<"$(names_to_lines)"

# 3. SOCKS-прокси, указывающий на порт, который никто не слушает.
while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    state="$($NS -getsocksfirewallproxy "$svc" 2>/dev/null)"
    enabled=$(echo "$state" | awk -F': ' '/^Enabled:/{print $2}')
    host=$(echo "$state" | awk -F': ' '/^Server:/{print $2}')
    port=$(echo "$state" | awk -F': ' '/^Port:/{print $2}')
    [ "$enabled" = "Yes" ] || continue
    case "$host" in 127.*) ;; *) continue ;; esac
    if ! /usr/bin/nc -z -w 1 127.0.0.1 "$port" 2>/dev/null; then
        say "SOCKS-прокси «$svc» = $host:$port, а слушать там некому"
    fi
done <<<"$(names_to_lines)"

# 4. Журнал хелпера и pf-якорь — видны только из-под root.
if [ -r "$JOURNAL" ]; then
    JOURNAL_READABLE=1
    dns_count="$(/usr/bin/plutil -extract dns raw -o - "$JOURNAL" 2>/dev/null | wc -w | tr -d ' ')"
    token="$(/usr/bin/plutil -extract pfToken raw -o - "$JOURNAL" 2>/dev/null)"
    echo "  журнал хелпера: записей DNS=$dns_count, pf-токен=${token:-нет}"
    [ -n "$token" ] && [ "$token" != "does not exist" ] && say "в журнале живёт pf-токен — вырубор все ещё включён"
else
    echo "  журнал хелпера не читается (нужен sudo) — пропущено"
fi
if [ "$(id -u)" = 0 ]; then
    SUDO_NEEDED=0
    if /sbin/pfctl -a "$ANCHOR" -s rules 2>/dev/null | grep -q .; then
        say "pf-якорь $ANCHOR содержит правила — трафик может блокироваться"
    fi
else
    echo "  правила pf без sudo не видны — пропущено"
fi

if [ "$PROBLEM" = 1 ]; then
    echo "— найдены следы прошлой сессии; починка: sudo bash Scripts/anemia-network-reset.sh"
    exit 1
fi
if [ "$JOURNAL_READABLE" = 0 ] || [ "$SUDO_NEEDED" = 1 ]; then
    echo "— видимое чисто, но журнал хелпера и pf не проверены: повтори под sudo"
    exit 2
fi
echo "— чисто: ни мёртвых маршрутов, ни прибитого DNS, ни висячего прокси"
