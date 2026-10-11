#!/usr/bin/env bash
#
# End-to-end check of Anemia's AmneziaWG configs against the real engine — no
# root, no network beyond fetching the pinned source:
#
#   1. clone amneziawg-go at the pinned tag (the one fetch-extra-engines.sh builds);
#   2. generate WireGuard keys and an AmneziaWG 3.1 client conf (S1–S4, H1–H4
#      ranges, I1, junk, header protection, content padding, timings, trailers);
#   3. render the client UAPI script with LoaderTool — the exact code path the
#      app pushes through the helper;
#   4. run Scripts/awg-harness inside the engine's own test package: a server
#      and a client device over real loopback UDP, handshake, then traffic both
#      ways (plus a control proving base64 keys are refused).
#
#   bash Scripts/verify-awg-engine.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${SCRATCH:-/tmp/loader-build}"
WORK="$SCRATCH/awg-verify"
AWG_GO_REF="${AWG_GO_REF:-v3.1.20260828}"
source "$ROOT/Scripts/toolchain-env.sh"

if [[ -z "${GO:-}" ]]; then
  if command -v go >/dev/null; then GO=go
  elif [[ -x "$SCRATCH/toolchains/go/bin/go" ]]; then GO="$SCRATCH/toolchains/go/bin/go"
  else echo "✗ Go is required (https://go.dev/dl)" >&2; exit 1; fi
fi
[[ -x "$ROOT/Resources/xray" ]] || { echo "✗ Resources/xray is needed for key generation (Scripts/fetch-cores.sh)" >&2; exit 1; }
export GOMODCACHE="${GOMODCACHE:-$SCRATCH/toolchains/gopath/pkg/mod}"
export GOCACHE="${GOCACHE:-$SCRATCH/toolchains/gocache}"
export GOTOOLCHAIN=local

rm -rf "$WORK" && mkdir -p "$WORK"
echo "→ amneziawg-go @ $AWG_GO_REF"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$AWG_GO_REF" \
    https://github.com/amnezia-vpn/amneziawg-go "$WORK/src"
cp "$ROOT/Scripts/awg-harness/anemia_harness_test.go" "$WORK/src/device/"

echo "→ LoaderTool"
swift build --scratch-path "$SCRATCH" --product LoaderTool \
    ${TOOLCHAIN_SWIFT_ARGS[@]+"${TOOLCHAIN_SWIFT_ARGS[@]}"} >/dev/null
TOOL="$(swift build --scratch-path "$SCRATCH" --show-bin-path)/LoaderTool"

echo "→ keys and an AmneziaWG 3.1 client conf"
python3 - "$ROOT/Resources/xray" > "$WORK/keys.env" <<'PY'
import base64, os, re, subprocess, sys
def pair():
    out = subprocess.run([sys.argv[1], "wg"], capture_output=True, text=True, check=True).stdout
    values = re.findall(r":\s*(\S+)", out)
    def std(v):
        v = v.replace("-", "+").replace("_", "/")
        return v + "=" * (-len(v) % 4)
    return std(values[0]), std(values[1])
client_priv, client_pub = pair()
server_priv, server_pub = pair()
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
for key, value in [("CLIENT_PRIV", client_priv), ("CLIENT_PUB", client_pub), ("SERVER_PRIV", server_priv),
                   ("SERVER_PUB", server_pub), ("HPK", base64.b64encode(os.urandom(32)).decode()), ("AWG_PORT", port)]:
    print(f'{key}="{value}"')
PY
set -a; source "$WORK/keys.env"; set +a
cat > "$WORK/client.conf" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIV
Address = 10.66.0.2/32
MTU = 1280
Jc = 4
Jmin = 40
Jmax = 90
S1 = 24
S2 = 40
S3 = 18
S4 = 16
H1 = 100000-100050
H2 = 200000-200050
H3 = 300000-300050
H4 = 400000-400050
I1 = <r 64>
HeaderProtectionKey = $HPK
ContentPaddingAddition = 8-24
RekeyAfterTime = 110-130
KeepaliveTimeout = 9-11
MaxHandshakeAttempts = 18-22
RandomTrailers = on
DisableCookies = off

[Peer]
PublicKey = $SERVER_PUB
AllowedIPs = 10.66.0.1/32
Endpoint = 127.0.0.1:$AWG_PORT
PersistentKeepalive = 5
EOF
"$TOOL" awg-uapi "$WORK/client.conf" > "$WORK/client.uapi"

echo "→ engine harness"
harness_log="$WORK/harness.log"
(cd "$WORK/src" && ANEMIA_CLIENT_UAPI="$WORK/client.uapi" \
    "$GO" test ./device -run 'TestAnemia' -count=1 -v) > "$harness_log" 2>&1
grep -E "^(ok|FAIL|--- )|attempt|steady|did not|rejected|refused|client (last_handshake|tx_bytes|rx_bytes)" "$harness_log" \
  | sed 's/^ *//'
# A -run regex that matches no test exits 0 and prints "[no tests to run]", and
# `ok` on the last line made this script report a verified engine while it had
# run nothing. Count what actually passed, and fail on zero.
ran=$(grep -c '^--- PASS: TestAnemia' "$harness_log" || true)
[[ "${ran:-0}" -ge 1 ]] \
  || { echo "✗ the harness ran no TestAnemia checks — -run and Scripts/awg-harness/ have drifted apart" >&2; exit 1; }
echo "→ engine harness: $ran checks passed"
