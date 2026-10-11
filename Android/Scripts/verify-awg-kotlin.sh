#!/usr/bin/env bash
#
# UAPI-скрипт, который собирает Kotlin-порт, прогоняется через настоящий
# `amneziawg-go`: тот же харнес, что и `Scripts/verify-awg-engine.sh`, но
# клиентский скрипт в него приходит из `core/…/Awg.kt`, а не из Swift.
#
# Золотые сверки отвечают за «Kotlin совпадает с Swift», движок — за «то, что
# Kotlin собрал, настоящий AmneziaWG принимает и по нему идут пакеты». Это
# разные утверждения, и второе золотом не доказывается: у обеих сторон может
# быть один и тот же неверный ключ.
#
#   bash Android/Scripts/verify-awg-kotlin.sh
#
set -euo pipefail

ANDROID_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$ANDROID_DIR/.." && pwd)"
source "$ANDROID_DIR/Scripts/kotlin-env.sh"

WORK="${AWG_KOTLIN_WORK:-/tmp/anemia-awg-kotlin}"
SRC="${AWG_GO_SRC:-$HOME/Library/Caches/Anemia/android-core/awg-src}"
GO="${GO:-$HOME/Library/Caches/Anemia/toolchains/go1.27.1/bin/go}"
AWG_GO_REF="${AWG_GO_REF:-v3.1.20260828}"
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
cp "$ROOT/Scripts/awg-harness/anemia_harness_test.go" "$SRC/device/"

rm -rf "$WORK" && mkdir -p "$WORK/classes"

echo "→ kotlinc: :core + CLI эмиттера"
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(find "$ANDROID_DIR/core/src/main/kotlin" -name '*.kt' | sort)
sources+=("$ANDROID_DIR/Scripts/awg-uapi-kotlin/main.kt")
"$KOTLINC" -nowarn -jvm-target 17 -d "$WORK/classes" "${sources[@]}"

echo "→ ключи и AmneziaWG 3.1 конфиг"
python3 - "$ROOT/Resources/xray" > "$WORK/keys.env" <<'PY'
import base64, os, re, socket, subprocess, sys
def pair():
    out = subprocess.run([sys.argv[1], "wg"], capture_output=True, text=True, check=True).stdout
    values = re.findall(r":\s*(\S+)", out)
    def std(v):
        v = v.replace("-", "+").replace("_", "/")
        return v + "=" * (-len(v) % 4)
    return std(values[0]), std(values[1])
client_priv, client_pub = pair()
server_priv, server_pub = pair()
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
pairs = [("CLIENT_PRIV", client_priv), ("CLIENT_PUB", client_pub), ("SERVER_PRIV", server_priv),
         ("SERVER_PUB", server_pub), ("HPK", base64.b64encode(os.urandom(32)).decode()), ("AWG_PORT", str(port))]
for key, value in pairs: print(f'{key}="{value}"')
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

echo "→ UAPI из Kotlin"
java -cp "$WORK/classes:$KOTLIN_STDLIB" MainKt "$WORK/client.conf" "127.0.0.1" > "$WORK/client.uapi"
[[ $(head -1 "$WORK/client.uapi") == "set=1" ]] || { echo "✗ скрипт не начинается с set=1" >&2; exit 1; }
lines=$(grep -c . "$WORK/client.uapi")
# Пустой или однострочный вывод — это не «конфиг собрался», а тихая поломка.
[[ "$lines" -gt 20 ]] || { echo "✗ строк UAPI: $lines — слишком мало, ключевые параметры не доехали" >&2; exit 1; }
# Каждый параметр обфускации обязан доехать до скрипта: движок на отсутствующий
# ключ молча берёт значение по умолчанию, и «совпадает с Swift» это не ловит.
for key in jc= jmin= jmax= s1= s2= s3= s4= h1= h2= h3= h4= i1= header_protection_key= \
           content_padding_addition= rekey_after_time= keepalive_timeout= \
           max_handshake_attempts= random_trailers= disable_cookies= endpoint= allowed_ip=; do
    grep -q "^$key" "$WORK/client.uapi" || { echo "✗ в UAPI нет строки $key" >&2; exit 1; }
done
echo "   строк: $lines"

echo "→ движок: рукопожатие и пакеты в обе стороны"
log="$WORK/harness.log"
(cd "$SRC" && ANEMIA_CLIENT_UAPI="$WORK/client.uapi" CLIENT_PRIV="$CLIENT_PRIV" \
    SERVER_PRIV="$SERVER_PRIV" CLIENT_PUB="$CLIENT_PUB" AWG_PORT="$AWG_PORT" \
    "$GO" test ./device -run 'TestAnemia' -count=1 -v) > "$log" 2>&1 || true

grep -E "attempt|steady|refused|did not|FAIL|ok  " "$log" | sed 's/^ *//' | head -12
ran=$(grep -c '^--- PASS: TestAnemia' "$log" || true)
[[ "${ran:-0}" -ge 2 ]] || { echo "✗ прошло тестов: $ran (ожидалось 2) — вывод харнеса в $log" >&2; exit 1; }
echo "✓ Kotlin-скрипт принят движком: $ran теста, steady-state и отказ на base64-ключе на месте"
