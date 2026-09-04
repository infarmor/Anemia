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
HELPER_BIN="$SCRATCH/debug/LoaderHelper"
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
</dict>
</plist>
PLISTEOF
chown root:wheel "$PLIST"
chmod 0644 "$PLIST"

echo "→ Loading service"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
echo "Done. Helper '$LABEL' is registered. Connect from the app to test."
