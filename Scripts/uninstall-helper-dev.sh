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

launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
rm -f "$TOOLS_DIR/$LABEL" "$TOOLS_DIR/tun2socks"
echo "Removed $LABEL."
