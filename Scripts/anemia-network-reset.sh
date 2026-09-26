#!/bin/bash
#
# Anemia network reset — brings a Mac's network back after any Anemia/Loader
# session, with or without the app. Idempotent; safe to run at any time.
#
#   sudo bash Scripts/anemia-network-reset.sh             # repair
#   sudo bash Scripts/anemia-network-reset.sh --uninstall # repair + remove helper
#
# What it undoes:
#   * the kill switch (Anemia's pf anchor, a recorded pf reference, and the
#     main-ruleset kill switch of pre-0.8 helpers)
#   * tun2socks / amneziawg-go processes orphaned from the helper's install dir
#   * split-default routes left on utun interfaces that no longer exist
#   * system DNS / SOCKS proxy overrides recorded in the helper's journal
#     (restored to exactly what they were), plus resolvers still pinned to
#     Anemia's tunnel ranges and loopback SOCKS proxies nothing listens on
#
# Dependency-free on a stock macOS: bash 3.2, plutil, networksetup, pfctl, nc
# (no python — on a Mac without developer tools `python3` is only a stub).
set -u

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo:  sudo bash $0 $*"
    exit 1
fi

LABEL="com.loader.vpn.helper"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
TOOLS="/Library/PrivilegedHelperTools"
STATE="/var/db/Loader"
JOURNAL="$STATE/network-journal.json"
ANCHOR="com.apple/000.AnemiaKillSwitch"
NS=/usr/sbin/networksetup
UNINSTALL=0
[ "${1:-}" = "--uninstall" ] && UNINSTALL=1
CHANGED=0

say() { echo "• $*"; CHANGED=1; }
jget() { /usr/bin/plutil -extract "$1" raw -o - "$JOURNAL" 2>/dev/null; }

# Tunnel-range resolvers (current 172.28/172.29, legacy 198.18) — ours.
is_tunnel_resolver() {
    case "$1" in 172.28.0.*|172.29.0.*|198.18.0.*) return 0 ;; esac
    return 1
}
LIVE_V4="$(/sbin/ifconfig -a 2>/dev/null | awk '$1=="inet"{print $2}')"
held_locally() {
    prefix="$(echo "$1" | cut -d. -f1-3)"
    echo "$LIVE_V4" | grep -q "^${prefix//./\\.}\\."
}
current_dns() {
    $NS -getdnsservers "$1" 2>/dev/null | grep -E '^[0-9a-fA-F:.]+$' | tr '\n' ' ' | sed 's/ *$//'
}

# 1. Stop the helper daemon. A 0.8+ helper restores everything on SIGTERM.
if [ -f "$PLIST" ]; then
    /bin/launchctl bootout system "$PLIST" >/dev/null 2>&1 && say "stopped the helper daemon"
fi

# 2. Kill switch.
/sbin/pfctl -a "$ANCHOR" -F rules >/dev/null 2>&1
TOKEN=""
[ -f "$JOURNAL" ] && TOKEN="$(jget pfToken)"
if [ -z "$TOKEN" ] && [ -r "$STATE/killswitch.token" ]; then
    TOKEN="$(tr -dc '0-9' < "$STATE/killswitch.token")"
fi
if [ -n "$TOKEN" ]; then
    /sbin/pfctl -X "$TOKEN" >/dev/null 2>&1
    say "released the kill switch's pf reference"
fi
MAIN_RULES="$(/sbin/pfctl -s rules 2>/dev/null)"
if echo "$MAIN_RULES" | grep -q '^block drop out all' && ! echo "$MAIN_RULES" | grep -q '^anchor "com.apple/\*"'; then
    /sbin/pfctl -f /etc/pf.conf >/dev/null 2>&1 && say "restored the stock pf ruleset (pre-0.8 kill switch)"
fi

# 3. Orphaned bridges running from the helper's install directory.
for pid in $(/usr/bin/pgrep -f "$TOOLS/(tun2socks|amneziawg-go)" 2>/dev/null); do
    exe="$(ps -o comm= -p "$pid" 2>/dev/null)"
    case "$exe" in
        "$TOOLS/tun2socks"|"$TOOLS/amneziawg-go")
            kill -TERM "$pid" 2>/dev/null && say "stopped orphaned $exe (pid $pid)" ;;
    esac
done

# 4. Split-default routes on utun interfaces that no longer exist.
/usr/sbin/netstat -rn -f inet | awk '$1=="0/1"||$1=="0.0.0.0/1"||$1=="128/1"||$1=="128.0.0.0/1"{print $1" "$4}' |
while read -r dest iface; do
    case "$dest" in 0/1) dest="0.0.0.0/1" ;; 128/1) dest="128.0.0.0/1" ;; esac
    case "$iface" in
        utun*) /sbin/ifconfig "$iface" >/dev/null 2>&1 ||
            { /sbin/route -n delete -net "$dest" -interface "$iface" >/dev/null 2>&1 && echo "• removed stale route $dest ($iface)"; } ;;
    esac
done
/usr/sbin/netstat -rn -f inet6 | awk '$1=="::/1"||$1=="8000::/1"{print $1" "$4}' |
while read -r dest iface; do
    case "$iface" in
        utun*) /sbin/ifconfig "$iface" >/dev/null 2>&1 ||
            { /sbin/route -n delete -inet6 -net "$dest" -interface "$iface" >/dev/null 2>&1 && echo "• removed stale route $dest ($iface)"; } ;;
    esac
done

# 5. Journal: put recorded DNS / proxy overrides back — only where the setting
#    still holds the value Anemia applied (a later user change is left alone).
if [ -f "$JOURNAL" ]; then
    n="$(jget dns)"; n="${n:-0}"; i=0
    while [ "$i" -lt "$n" ]; do
        svc="$(jget "dns.$i.service")"
        applied=""; c="$(jget "dns.$i.applied")"; j=0
        while [ "$j" -lt "${c:-0}" ]; do applied="$applied $(jget "dns.$i.applied.$j")"; j=$((j+1)); done
        applied="$(echo "$applied" | sed 's/^ *//')"
        cur="$(current_dns "$svc")"
        ours=0
        if [ -n "$applied" ]; then
            [ "$cur" = "$applied" ] && ours=1
        elif [ -n "$cur" ]; then
            ours=1
            for ip in $cur; do is_tunnel_resolver "$ip" || ours=0; done
        fi
        if [ "$ours" = 1 ]; then
            set --
            c="$(jget "dns.$i.prior")"; j=0
            while [ "$j" -lt "${c:-0}" ]; do set -- "$@" "$(jget "dns.$i.prior.$j")"; j=$((j+1)); done
            if [ "$#" -eq 0 ]; then $NS -setdnsservers "$svc" empty; else $NS -setdnsservers "$svc" "$@"; fi
            say "DNS $svc → ${*:-automatic}"
        fi
        i=$((i+1))
    done

    n="$(jget proxy)"; n="${n:-0}"; i=0
    while [ "$i" -lt "$n" ]; do
        svc="$(jget "proxy.$i.service")"
        aport="$(jget "proxy.$i.applied.port")"
        state="$($NS -getsocksfirewallproxy "$svc" 2>/dev/null)"
        cur_on="$(echo "$state" | awk -F': ' '$1=="Enabled"{print $2}')"
        cur_host="$(echo "$state" | awk -F': ' '$1=="Server"{print $2}')"
        cur_port="$(echo "$state" | awk -F': ' '$1=="Port"{print $2}')"
        if [ "$cur_on" = "Yes" ] && case "$cur_host" in 127.*|localhost|::1) true ;; *) false ;; esac \
           && { [ "${aport:-0}" = "0" ] || [ "$cur_port" = "$aport" ]; }; then
            if [ "$(jget "proxy.$i.prior.enabled")" = "true" ]; then
                $NS -setsocksfirewallproxy "$svc" "$(jget "proxy.$i.prior.host")" "$(jget "proxy.$i.prior.port")"
                $NS -setsocksfirewallproxystate "$svc" on
                say "proxy $svc → restored previous proxy"
            else
                $NS -setsocksfirewallproxystate "$svc" off
                say "proxy $svc → off"
            fi
        fi
        i=$((i+1))
    done
    rm -f "$JOURNAL"
fi

# 5b. Pre-0.8 backup files: their pins are reset by the sweep below (to
#     automatic — the helper's own --restore-network restores exact values).
rm -f "$STATE/dns.backup.json" "$STATE/proxy.backup.json" "$STATE/killswitch.token"

# 6. Sweep every service for pins that cannot work.
$NS -listallnetworkservices 2>/dev/null | tail -n +2 | sed 's/^\*//' |
while IFS= read -r svc; do
    [ -z "$svc" ] && continue
    cur="$(current_dns "$svc")"
    if [ -n "$cur" ]; then
        dead=1
        for ip in $cur; do
            if ! is_tunnel_resolver "$ip" || held_locally "$ip"; then dead=0; fi
        done
        if [ "$dead" = 1 ]; then
            $NS -setdnsservers "$svc" empty && echo "• DNS $svc: dead tunnel resolver ($cur) → automatic"
        fi
    fi
    state="$($NS -getsocksfirewallproxy "$svc" 2>/dev/null)"
    on="$(echo "$state" | awk -F': ' '$1=="Enabled"{print $2}')"
    host="$(echo "$state" | awk -F': ' '$1=="Server"{print $2}')"
    port="$(echo "$state" | awk -F': ' '$1=="Port"{print $2}')"
    if [ "$on" = "Yes" ]; then
        case "$host" in
            127.*|localhost|::1)
                if ! /usr/bin/nc -z -G 1 127.0.0.1 "$port" >/dev/null 2>&1; then
                    $NS -setsocksfirewallproxystate "$svc" off && echo "• proxy $svc: dead loopback proxy $host:$port → off"
                fi ;;
        esac
    fi
done

# 7. Make restored resolvers effective for running apps.
/usr/bin/dscacheutil -flushcache 2>/dev/null
/usr/bin/killall -HUP mDNSResponder 2>/dev/null

# 8. Helper: remove, or bring the daemon back (it finds a clean journal).
if [ "$UNINSTALL" = 1 ]; then
    rm -f "$PLIST" "$TOOLS/$LABEL" "$TOOLS/tun2socks" "$TOOLS/amneziawg-go"
    rm -rf "$STATE"
    say "removed the Anemia helper"
elif [ -f "$PLIST" ]; then
    /bin/launchctl bootstrap system "$PLIST" >/dev/null 2>&1
fi

[ "$CHANGED" = 1 ] || echo "No Anemia leftovers found."
echo "Done. DNS cache flushed."
