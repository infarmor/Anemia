#!/usr/bin/env bash
#
# Train, evaluate and optionally install kxc v4 — the server-quality forecast
# model. Pure macOS SDK (CreateML + Core ML): no Python, no downloads.
#
#   bash Scripts/train-kxc.sh             # train + scoreboard
#   bash Scripts/train-kxc.sh --install   # …and install it if it beats every baseline
#
# The shipped model is kept as $OUT/kxc-previous.mlmodelc the first time this
# runs, so the scoreboard always compares against it and the swap is reversible.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Scripts/toolchain-env.sh"
OUT="${SCRATCH:-/tmp/loader-build}/kxc"
mkdir -p "$OUT"

if [[ ! -e "$OUT/kxc-previous.mlmodelc" && -e "$ROOT/Sources/LoaderApp/Resources/kxc.mlmodelc" ]]; then
    cp -R "$ROOT/Sources/LoaderApp/Resources/kxc.mlmodelc" "$OUT/kxc-previous.mlmodelc"
fi

echo "→ Building the trainer"
swiftc -O ${SDKROOT:+-sdk "$SDKROOT"} \
    "$ROOT/Sources/LoaderCore/ServerScoring.swift" \
    "$ROOT/Sources/LoaderCore/KxcFeatures.swift" \
    "$ROOT/Scripts/kxc/main.swift" \
    -o "$OUT/kxc-train" 2> >(grep -v "deprecated\|DeprecatedDeclaration" >&2 || true)

"$OUT/kxc-train" --repo "$ROOT" --out "$OUT" "$@"
