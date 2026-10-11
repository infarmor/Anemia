#!/usr/bin/env bash
#
# Живой AmneziaWG-пир для проверки ветки `awg://` на устройстве.
#
# В README этот пункт висел первым в «незакрытых рисках»: движок на Android
# поднимается (setMTU/netlink убраны переходом на `CreateUnmonitoredTUNFromFD`),
# но рукопожатие с настоящим сервером никто не видел. Скрипт поднимает сервер
# `amneziawg-go` на настоящем UDP-порту — тем же способом, что
# `Scripts/verify-awg-engine.sh`, только не в паре «клиент-устройство в одном
# процессе», а один: клиентом должен стать эмулятор.
#
#   bash Android/Scripts/awg-peer.sh [порт]        # пир поднимается и ждёт
#
# Печатает конфиг для вставки в приложение и ждёт рукопожатия; как только
# `last_handshake_time_sec` перестал нулём и `rx_bytes` двинулся — говорит
# «PEER VERIFIED» и выходит нулём (иначе — не-нулём после таймаута).
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${AWG_PEER_WORK:-/tmp/anemia-awg-peer}"
AWG_GO_REF="${AWG_GO_REF:-v3.1.20260828}"
SRC="${AWG_GO_SRC:-$HOME/Library/Caches/Anemia/android-core/awg-src}"
GO="${GO:-$HOME/Library/Caches/Anemia/toolchains/go1.27.1/bin/go}"
export GOMODCACHE="${GOMODCACHE:-$HOME/Library/Caches/Anemia/gopath/pkg/mod}"
export GOCACHE="${GOCACHE:-$HOME/Library/Caches/Anemia/gocache}"
export GOTOOLCHAIN=local

[[ -x "$GO" ]] || { echo "✗ нет Go по $GO" >&2; exit 1; }
[[ -x "$ROOT/Resources/xray" ]] || { echo "✗ нужен Resources/xray для генерации ключей" >&2; exit 1; }

if [[ ! -d "$SRC/device" ]]; then
    echo "→ клона amneziawg-go нет — собираю $AWG_GO_REF в $SRC"
    mkdir -p "$(dirname "$SRC")"
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$AWG_GO_REF" \
        https://github.com/amnezia-vpn/amneziawg-go "$SRC"
fi
cp "$ROOT/Scripts/awg-harness/awg_live_peer_test.go" "$SRC/device/"

echo "→ LoaderTool (нужен, чтобы отрисовать серверный UAPI-скрипт)"
SCRATCH="${SCRATCH:-/tmp/loader-build}"
swift build --scratch-path "$SCRATCH" --product LoaderTool >/dev/null
TOOL="$(swift build --scratch-path "$SCRATCH" --show-bin-path)/LoaderTool"

mkdir -p "$WORK"
PORT="${1:-$("$ROOT/Resources/xray" --version >/dev/null 2>&1; python3 -c 'import socket;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')}"

echo "→ ключи"
python3 - "$ROOT/Resources/xray" > "$WORK/keys.env" <<'PY'
import base64, re, subprocess, sys
def pair():
    out = subprocess.run([sys.argv[1], "wg"], capture_output=True, text=True, check=True).stdout
    values = re.findall(r":\s*(\S+)", out)
    def std(v):
        v = v.replace("-", "+").replace("_", "/")
        return v + "=" * (-len(v) % 4)
    return std(values[0]), std(values[1])
cp, cu = pair(); sp, su = pair()
h = lambda b: base64.b64decode(b).hex()
print(f'CLIENT_PRIV="{cp}"\nCLIENT_PUB="{cu}"\nCLIENT_PUB_HEX="{h(cu)}"')
print(f'SERVER_PRIV="{sp}"\nSERVER_PRIV_HEX="{h(sp)}"\nSERVER_PUB="{su}"\nSERVER_PUB_HEX="{h(su)}"')
PY
set -a; source "$WORK/keys.env"; set +a

cat > "$WORK/client.conf" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIV
Address = 10.66.0.2/32
DNS = 1.1.1.1
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
HeaderProtectionKey = $(python3 -c 'import base64,os;print(base64.b64encode(os.urandom(32)).decode())')
ContentPaddingAddition = 8-24
RandomTrailers = on
DisableCookies = off

[Peer]
PublicKey = $SERVER_PUB
AllowedIPs = 0.0.0.0/0
Endpoint = 10.0.2.2:$PORT
PersistentKeepalive = 5
EOF

"$TOOL" awg-uapi "$WORK/client.conf" > "$WORK/client.uapi"

# Сервер берёт те же самые параметры обфускации: за ними идут строки клиента до
# `replace_peers=`, а свои ключ и порт дописываются. Тот же рецепт, что у
# `Scripts/awg-harness`.
python3 - "$WORK/client.uapi" "$WORK/server.uapi" "$SERVER_PRIV_HEX" "$PORT" "$CLIENT_PUB_HEX" <<'PY'
import sys
client, out, priv, port, peer = sys.argv[1:6]
lines = [l for l in open(client).read().split("\n") if l.strip()]
assert lines[0] == "set=1", "скрипт клиента должен начинаться с set=1"
keep = []
for line in lines[1:]:
    if line.startswith("replace_peers="):
        break
    if line.startswith("private_key=") or line.startswith("listen_port="):
        continue
    keep.append(line)
server = ["set=1", f"private_key={priv}", f"listen_port={port}", *keep,
          "replace_peers=true", f"public_key={peer}", "protocol_version=1",
          "replace_allowed_ips=true", "allowed_ip=10.66.0.2/32"]
open(out, "w").write("\n".join(server) + "\n")
print(f"   серверный скрипт: {len(server)} строк")
PY

cat > "$WORK/run.sh" <<EOF
#!/usr/bin/env bash
cd "$SRC"
AWG_PEER_UAPI="$WORK/server.uapi" AWG_WAIT_SEC="${AWG_WAIT_SEC:-180}" \\
  "$GO" test ./device -run 'TestAnemiaLivePeer' -count=1 -v -timeout 240s
EOF
chmod +x "$WORK/run.sh"

echo
echo "→ пир на порту $PORT UDP; конфиг клиента ($WORK/client.conf):"
sed 's/^/    /' "$WORK/client.conf"
echo
echo "→ вставить в Anemia на устройстве (поле «Добавить …» → «Добавить»), выбрать"
echo "   сервер и подключиться; пир ждёт ${AWG_WAIT_SEC:-180} с"
echo
echo "   adb shell am start -n app.anemia/.ui.MainActivity --es link \"\$(cat $WORK/client.conf)\""
echo "   adb shell uiautomator dump /sdcard/u.xml && adb shell cat /sdcard/u.xml | tr '<' '\n' | grep -o 'bounds=\"\\[[0-9,]*\\]\\[[0-9,]*\\]\"' | tail -1"
echo
exec "$WORK/run.sh"
