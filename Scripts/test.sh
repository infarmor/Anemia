#!/usr/bin/env bash
#
# Run every test suite (swift-testing). Works with full Xcode and with the
# standalone Command Line Tools. Extra arguments go to `swift test`, e.g.:
#
#   bash Scripts/test.sh
#   bash Scripts/test.sh --filter NetworkSafety
#
# MIN_TESTS (default 300) is the floor the full run has to clear; a filtered run
# is not measured against it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Outside the iCloud-managed Documents tree (see README).
SCRATCH="${SCRATCH:-/tmp/loader-build}"
MIN_TESTS="${MIN_TESTS:-300}"
source "$ROOT/Scripts/toolchain-env.sh"

cd "$ROOT"
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
# `tee` rather than a pipe: the exit status of `swift test` must survive.
set +e
swift test --scratch-path "$SCRATCH" ${TOOLCHAIN_SWIFT_ARGS[@]+"${TOOLCHAIN_SWIFT_ARGS[@]}"} "$@" 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e

if [[ $status -ne 0 ]]; then
    exit "$status"
fi

# A zero exit is not "the suite ran". `swift test` prints an XCTest
# "Executed 0 tests, with 0 failures" banner for targets that hold no XCTest
# cases at all — read alone, it looks like a run that passed — and a
# partially-discovered run prints the very same summary shape with a fraction of
# the cases. Sum what swift-testing actually reported and refuse to call a short
# run the whole suite. Filtered runs are excluded on purpose: they are supposed
# to be short.
total=$(awk '/Test run with [0-9]+ tests/ { for (i = 1; i <= NF; i++) if ($i == "with") { sum += $(i+1); break } } END { print sum+0 }' "$LOG")
if [[ "$*" != *--filter* ]]; then
    if (( total < MIN_TESTS )); then
        echo "✗ swift-testing ran only $total tests, under the $MIN_TESTS floor — a target was skipped, not passed" >&2
        exit 1
    fi
    echo "✓ $total tests"
elif (( total == 0 )); then
    # The same trap in miniature: a filter that names nothing runs zero tests
    # and exits 0 (`verify-awg-engine.sh` was fixed for exactly this). A typo in
    # a suite name has to be an error, not a green screen.
    echo "✗ no test matched the filter — 0 tests run" >&2
    exit 1
fi
