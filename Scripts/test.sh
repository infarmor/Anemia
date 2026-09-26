#!/usr/bin/env bash
#
# Run every test suite (swift-testing). Works with full Xcode and with the
# standalone Command Line Tools. Extra arguments go to `swift test`, e.g.:
#
#   bash Scripts/test.sh
#   bash Scripts/test.sh --filter NetworkSafety
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Outside the iCloud-managed Documents tree (see README).
SCRATCH="${SCRATCH:-/tmp/loader-build}"
source "$ROOT/Scripts/toolchain-env.sh"

cd "$ROOT"
swift test --scratch-path "$SCRATCH" ${TOOLCHAIN_SWIFT_ARGS[@]+"${TOOLCHAIN_SWIFT_ARGS[@]}"} "$@"
