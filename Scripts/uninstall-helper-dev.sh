#!/usr/bin/env bash
#
# Remove the dev LaunchDaemon helper installed by install-helper-dev.sh,
# restoring the network first (kill switch, routes, DNS, proxy).
#
#   sudo bash Scripts/uninstall-helper-dev.sh
#
set -euo pipefail
if [[ $EUID -ne 0 ]]; then echo "Run with sudo."; exit 1; fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The reset script stops the daemon (whose SIGTERM teardown restores the
# network), sweeps anything left, and removes the helper's files.
exec /bin/bash "$ROOT/Scripts/anemia-network-reset.sh" --uninstall
