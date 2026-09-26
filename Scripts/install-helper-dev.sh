#!/usr/bin/env bash
#
# DEV install of the privileged helper as a LaunchDaemon so the app's XPC
# connection (NSXPCConnection machServiceName) can reach it. Run with sudo.
#
#   sudo bash Scripts/install-helper-dev.sh
#
# This is for local development on an unsigned build. The app installs the
# same daemon itself (Settings → Privileged helper).
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run with sudo."; exit 1; fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Must match the scratch used for `swift build` (default mirrors build-app.sh).
SCRATCH="${SCRATCH:-/tmp/loader-build}"
# build-app.sh builds release; plain `swift build` is debug. Prefer release.
HELPER_BIN="$SCRATCH/release/LoaderHelper"
[[ -x "$HELPER_BIN" ]] || HELPER_BIN="$SCRATCH/debug/LoaderHelper"
TUN2SOCKS="$ROOT/Resources/tun2socks"
LABEL="com.loader.vpn.helper"
TOOLS_DIR="/Library/PrivilegedHelperTools"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

[[ -x "$HELPER_BIN" ]] || { echo "Build first: swift build --scratch-path $SCRATCH"; exit 1; }
[[ -x "$TUN2SOCKS" ]] || { echo "Missing Resources/tun2socks (run Scripts/fetch-cores.sh)"; exit 1; }

echo "→ Stopping the running helper (0.8+ restores the network on SIGTERM)"
launchctl bootout system "$PLIST" 2>/dev/null || true

echo "→ Installing helper + tun2socks to $TOOLS_DIR"
mkdir -p "$TOOLS_DIR"
install -m 0755 "$HELPER_BIN" "$TOOLS_DIR/$LABEL"
install -m 0755 "$TUN2SOCKS"  "$TOOLS_DIR/tun2socks"
# The root helper only runs a root-owned engine from here (EngineBinaryPolicy).
if [[ -x "$ROOT/Resources/amneziawg-go" ]]; then
  install -m 0755 -o root -g wheel "$ROOT/Resources/amneziawg-go" "$TOOLS_DIR/amneziawg-go"
fi

echo "→ Restoring anything a previous generation left behind"
# The freshly installed binary replays the journal (and migrates pre-0.8
# backups, releases a stale kill switch, kills orphaned bridges).
"$TOOLS_DIR/$LABEL" --restore-network || true

echo "→ Writing LaunchDaemon $PLIST"
# Mirrors HelperLaunchd.plist (Sources/LoaderShared) — see
# Packaging/LoaderHelper-launchd.plist for what each key is for.
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>MachServices</key><dict><key>$LABEL</key><true/></dict>
    <key>Program</key><string>$TOOLS_DIR/$LABEL</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key><string>Interactive</string>
    <key>ExitTimeOut</key><integer>20</integer>
    <key>EnvironmentVariables</key>
    <dict>
        <key>LOADER_CLIENT_REQUIREMENT</key><string>identifier "com.loader.vpn"</string>
    </dict>
</dict>
</plist>
PLISTEOF
chown root:wheel "$PLIST"
chmod 0644 "$PLIST"

echo "→ Loading service"
launchctl bootstrap system "$PLIST" 2>/dev/null || launchctl load "$PLIST"
echo "Done. Helper '$LABEL' is registered. Connect from the app to test."
