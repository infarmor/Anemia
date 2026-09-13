#!/usr/bin/env bash
#
# DEV install of the privileged helper as a LaunchDaemon so the app's XPC
# connection (NSXPCConnection machServiceName) can reach it. Run with sudo.
#
#   sudo bash Scripts/install-helper-dev.sh
#
# This is for local development on an unsigned build. Production installs go
# through SMAppService from inside the signed app instead.
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run with sudo."; exit 1; fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Must match the scratch used for `swift build` (default mirrors build-app.sh).
SCRATCH="${SCRATCH:-/tmp/loader-build}"
# build-app.sh builds release; plain `swift build` is debug. Prefer whichever
# LoaderHelper exists, newest first, so this works after either.
HELPER_BIN="$SCRATCH/release/LoaderHelper"
[[ -x "$HELPER_BIN" ]] || HELPER_BIN="$SCRATCH/debug/LoaderHelper"
TUN2SOCKS="$ROOT/Resources/tun2socks"
LABEL="com.loader.vpn.helper"
TOOLS_DIR="/Library/PrivilegedHelperTools"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

[[ -x "$HELPER_BIN" ]] || { echo "Build first: swift build --scratch-path $SCRATCH"; exit 1; }
[[ -x "$TUN2SOCKS" ]] || { echo "Missing Resources/tun2socks (run Scripts/fetch-cores.sh)"; exit 1; }

echo "→ Installing helper + tun2socks to $TOOLS_DIR"
mkdir -p "$TOOLS_DIR"
install -m 0755 "$HELPER_BIN" "$TOOLS_DIR/$LABEL"
install -m 0755 "$TUN2SOCKS"  "$TOOLS_DIR/tun2socks"

echo "→ Writing LaunchDaemon $PLIST"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>MachServices</key><dict><key>$LABEL</key><true/></dict>
    <key>Program</key><string>$TOOLS_DIR/$LABEL</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>EnvironmentVariables</key>
    <dict>
        <!-- Only the genuine app may talk to the root helper (ClientVerifier
             checks the signed identifier on every connection). -->
        <key>LOADER_CLIENT_REQUIREMENT</key><string>identifier "com.loader.vpn"</string>
    </dict>
</dict>
</plist>
PLISTEOF
chown root:wheel "$PLIST"
chmod 0644 "$PLIST"

echo "→ Cleaning up any tunnel the running helper owns"
# bootout sends SIGTERM (the helper now kills its bridge on the way down),
# but cover older generations too: an orphaned tun2socks survives the
# daemon's death, keeps holding the utun + split routes, and makes every
# subsequent connect fail its interface wait (the "tunnel half-works"
# state). Sweep before unload, while the old daemon still holds a live pid.
# Only processes whose executable is our installed bridge are killed:
# pkill -f matches the whole argument string, so a `tail -f`/editor holding
# that path in its argv must not be swept up.
for pid in $(pgrep -f "PrivilegedHelperTools/tun2socks" 2>/dev/null || true); do
    [ "$(ps -o comm= -p "$pid" 2>/dev/null)" = "/Library/PrivilegedHelperTools/tun2socks" ] \
        && kill -TERM "$pid" 2>/dev/null || true
done
# Release any kill-switch pf state the dying helper left (its SIGTERM handler
# cannot run pfctl — async-signal-safe only), or the machine stays blackholed.
if [[ -r /var/db/Loader/killswitch.token ]]; then
    /sbin/pfctl -X "$(cat /var/db/Loader/killswitch.token)" 2>/dev/null || true
fi
if [[ -f /etc/pf.conf ]]; then
    /sbin/pfctl -f /etc/pf.conf 2>/dev/null || true
else
    /sbin/pfctl -F all 2>/dev/null || true
fi
rm -f /var/db/Loader/killswitch.token
# Drop split-default routes only where their utun is dead: a coexisting VPN
# client (sing-box/clash auto_route) legitimately holds the same prefixes on
# a live interface of its own.
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
# The resolver may still point at the tunnel gateway. Restore the user's
# pre-override DNS from the helper's persisted backup when present — a blind
# reset-to-DHCP on every service would wipe manually configured resolvers.
if [[ -r /var/db/Loader/dns.backup.json ]]; then
    python3 - /var/db/Loader/dns.backup.json <<'PY' 2>/dev/null || true
import json, subprocess, sys
backup = json.load(open(sys.argv[1]))
for svc, servers in backup.items():
    args = ["networksetup", "-setdnsservers", svc] + (servers or ["empty"])
    subprocess.run(args, capture_output=True)
PY
    rm -f /var/db/Loader/dns.backup.json
fi
# The SOCKS proxy override points apps at the dying engine's port — restore
# each service's pre-override state (including "off") the same way.
if [[ -r /var/db/Loader/proxy.backup.json ]]; then
    python3 - /var/db/Loader/proxy.backup.json <<'PY' 2>/dev/null || true
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
    rm -f /var/db/Loader/proxy.backup.json
fi

echo "→ Loading service"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
echo "Done. Helper '$LABEL' is registered. Connect from the app to test."
