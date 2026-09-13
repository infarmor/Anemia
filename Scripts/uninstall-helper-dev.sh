#!/usr/bin/env bash
#
# Remove the dev LaunchDaemon helper installed by install-helper-dev.sh.
#   sudo bash Scripts/uninstall-helper-dev.sh
#
set -euo pipefail
if [[ $EUID -ne 0 ]]; then echo "Run with sudo."; exit 1; fi

LABEL="com.loader.vpn.helper"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
TOOLS_DIR="/Library/PrivilegedHelperTools"
STATE_DIR="/var/db/Loader"

launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
rm -f "$TOOLS_DIR/$LABEL" "$TOOLS_DIR/tun2socks"

# Release any kill-switch pf state the helper left behind. bootout/unload
# sends SIGTERM, whose handler can only do async-signal-safe work — it kills
# the bridge but cannot run pfctl — so an armed kill switch would otherwise
# keep the machine blackholed after the helper is gone.
if [[ -r "$STATE_DIR/killswitch.token" ]]; then
    /sbin/pfctl -X "$(cat "$STATE_DIR/killswitch.token")" 2>/dev/null || true
fi
if [[ -f /etc/pf.conf ]]; then
    /sbin/pfctl -f /etc/pf.conf 2>/dev/null || true
else
    /sbin/pfctl -F all 2>/dev/null || true
fi
rm -f "$STATE_DIR/killswitch.token"

# Drop stale split-default routes pinned to now-dead utuns (a crashed bridge's
# residue); live foreign VPN clients keep their own routes.
for row in $(/usr/sbin/netstat -rn -f inet | awk '$1=="0/1"||$1=="0.0.0.0/1"||$1=="128/1"||$1=="128.0.0.0/1"{print $1","$4}'); do
    dest="${row%,*}"; iface="${row#*,}"
    case "$dest" in 0/1|128/1) dest="${dest%/*}.0.0.0/${dest#*/}" ;; esac
    case "$iface" in utun*) /sbin/ifconfig "$iface" >/dev/null 2>&1 || \
        /sbin/route -n delete -net "$dest" -interface "$iface" 2>/dev/null || true ;; esac
done
for row in $(/usr/sbin/netstat -rn -f inet6 | awk '$1=="::/1"||$1=="8000::/1"{print $1","$4}'); do
    dest="${row%,*}"; iface="${row#*,}"
    case "$iface" in utun*) /sbin/ifconfig "$iface" >/dev/null 2>&1 || \
        /sbin/route -n delete -inet6 -net "$dest" -interface "$iface" 2>/dev/null || true ;; esac
done

# Restore the user's pre-override DNS (the helper's persisted backup), then
# clear the state dir.
if [[ -r "$STATE_DIR/dns.backup.json" ]]; then
    python3 - "$STATE_DIR/dns.backup.json" <<'PY' 2>/dev/null || true
import json, subprocess, sys
backup = json.load(open(sys.argv[1]))
for svc, servers in backup.items():
    args = ["networksetup", "-setdnsservers", svc] + (servers or ["empty"])
    subprocess.run(args, capture_output=True)
PY
    rm -f "$STATE_DIR/dns.backup.json"
fi

# Restore the user's pre-override SOCKS proxy the same way: the helper's
# persisted backup carries each service's own proxy state (including "off"),
# so apps aren't stranded pointing at a dead engine port after removal.
if [[ -r "$STATE_DIR/proxy.backup.json" ]]; then
    python3 - "$STATE_DIR/proxy.backup.json" <<'PY' 2>/dev/null || true
import json, subprocess, sys
backup = json.load(open(sys.argv[1]))
for svc, parts in backup.items():
    if len(parts) != 3:
        continue
    if parts[0] == "1" and parts[1] and parts[2]:
        subprocess.run(["networksetup", "-setsocksfirewallproxy", svc, parts[1], parts[2]], capture_output=True)
        subprocess.run(["networksetup", "-setsocksfirewallproxystate", svc, "on"], capture_output=True)
    else:
        subprocess.run(["networksetup", "-setsocksfirewallproxystate", svc, "off"], capture_output=True)
PY
    rm -f "$STATE_DIR/proxy.backup.json"
fi
echo "Removed $LABEL."
