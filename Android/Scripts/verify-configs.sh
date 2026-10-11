#!/usr/bin/env bash
#
# Прогоняет каждый эталонный конфиг движка через настоящий xray (`-test`), чтобы

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX="$ROOT/Android/core/src/test/resources/xray"
XRAY="${XRAY:-$ROOT/Resources/xray}"
[[ -x "$XRAY" ]] || { echo "✗ нет $XRAY (Scripts/fetch-cores.sh)" >&2; exit 1; }

# Число проверяемых конфигов закреплено: «принял N из N» проходит и тогда,
# когда до движка доехала половина каталога (glob не видит ни лишнего файла,
# ни пропущенного).
EXPECTED_CONFIGS=${EXPECTED_CONFIGS:-37}
ok=0; bad=0
for file in "$FIX"/*.json; do
    name="$(basename "$file" .json)"
    # На macOS нет utun-дескриптора, который отдаёт расширение, поэтому tun-inbound
    # и привязанные к нему правила снимаются: проверяется разбор конфига.
    python3 - "$file" /tmp/anemia-cfg.json <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d["inbounds"] = []
d["routing"]["rules"] = [r for r in d["routing"]["rules"] if "inboundTag" not in r]
json.dump(d, open(sys.argv[2], "w"))
PY
    if out="$("$XRAY" run -c /tmp/anemia-cfg.json -test 2>&1)" && [[ "$out" != *"Failed to start"* ]]; then
        ok=$((ok + 1))
    else
        bad=$((bad + 1))
        echo "✗ $name: $(printf '%s' "$out" | grep 'Failed to start' | tail -1 | cut -c1-120)"
    fi
done
echo "— движок принял $ok из $((ok + bad)) эталонных конфигов (ожидалось $EXPECTED_CONFIGS)"
if [[ $((ok + bad)) -ne $EXPECTED_CONFIGS ]]; then
    echo "✘ до движка дошло $((ok + bad)) конфигов, а в эталоне $EXPECTED_CONFIGS" >&2
    exit 1
fi
[[ $bad -eq 0 ]]
