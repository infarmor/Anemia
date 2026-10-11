#!/usr/bin/env bash
#
# Контур маскирования: каждая строка эталона грамматики прогоняется через
# настоящий движок (`xray run -test`), и сверяется с записанным вердиктом.
#
# Зачем: `settings.noises` и `settings.fragment` движок читает строго, поэтому
# фильтр в `MaskingEmission.swift` (и его Kotlin-зеркало) — это не «нравится /
# не нравится», а «движок примет / не примет». Ошибиться в одну сторону —
# потерять дженк-пакет, в другую — конфиг, который не стартует. Таблица
# перемеряется здесь, так что смена движка краснеет тут, а не на устройстве.
#
#   bash Scripts/verify-noise-grammar.sh            # Resources/xray
#   XRAY=/path/to/xray bash Scripts/verify-noise-grammar.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/Android/core/src/test/resources/mask/grammar.tsv"
XRAY="${XRAY:-$ROOT/Resources/xray}"
[[ -x "$XRAY" ]] || { echo "✗ нет $XRAY (Scripts/fetch-cores.sh)" >&2; exit 1; }
[[ -r "$FIX" ]] || { echo "✗ нет $FIX" >&2; exit 1; }

# Этаж: пустой обход — не зелёный обход. Число строк закреплено, а вердикты
# разложены по полкам — обход, который всегда выдаёт «accept», краснеет на
# отбракованных строках, а не молчит.
EXPECTED_ROWS=${EXPECTED_ROWS:-99}
EXPECTED_ACCEPT=${EXPECTED_ACCEPT:-54}
EXPECTED_REJECT=${EXPECTED_REJECT:-45}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Разбором TSV заведует python: tab для shell-`read` — это IFS-пробел, и
# пустое поле в строке («str» с пустым пакетом) схлопывается, сдвигая
# остальные колонки влево. Первая версия этого контура именно так и врала.
python3 - "$FIX" "$WORK" <<'PY'
import json, pathlib, sys

fix, work = sys.argv[1], sys.argv[2]
manifest = []
count = 0
for raw in pathlib.Path(fix).read_text(encoding="utf-8").splitlines():
    if raw.startswith("#") or not raw.strip():
        continue
    fields = raw.split("\t")
    if len(fields) != 5:
        sys.exit(f"строка из {len(fields)} полей, ждалось 5: {raw!r}")
    kind, a, b, c, verdict = fields
    if verdict not in ("accept", "reject"):
        sys.exit(f"невердикт {verdict!r} в строке {raw!r}")
    if kind not in ("noise", "frag"):
        sys.exit(f"неизвестный kind {kind!r}")
    def space(v):
        return v.replace("%20", " ")
    if kind == "noise":
        settings = {"domainStrategy": "AsIs",
                    "noises": [{"type": space(a), "packet": space(b), "delay": space(c)}]}
    else:
        settings = {"domainStrategy": "AsIs",
                    "fragment": {"packets": space(a), "length": space(b), "interval": space(c)}}
    count += 1
    name = f"{count:03d}.json"
    config = {"log": {"loglevel": "error"},
              "inbounds": [{"tag": "socks", "listen": "127.0.0.1", "port": 41998,
                            "protocol": "socks"}],
              "outbounds": [{"tag": "frag", "protocol": "freedom", "settings": settings},
                            {"protocol": "blackhole"}]}
    pathlib.Path(work, name).write_text(json.dumps(config), encoding="utf-8")
    desc = f"{kind} {a or '∅'} | {b or '∅'} | {c or '∅'}"
    manifest.append(f"{name}\t{verdict}\t{desc}")
pathlib.Path(work, "manifest.tsv").write_text("\n".join(manifest) + "\n", encoding="utf-8")
print(f"— эталон разобран: {count} строк")
PY

total=0; accept=0; reject=0; wrong=0
while IFS=$'\t' read -r name verdict desc; do
    total=$((total + 1))
    if "$XRAY" run -test -c "$WORK/$name" > "$WORK/out.txt" 2>&1 \
       && ! grep -q "Failed to start" "$WORK/out.txt"; then
        got=accept
    else
        got=reject
    fi
    if [[ $got == accept ]]; then accept=$((accept + 1)); else reject=$((reject + 1)); fi
    if [[ $got != $verdict ]]; then
        wrong=$((wrong + 1))
        printf '✘ %-52s движок: %s, эталон: %s\n' "$desc" "$got" "$verdict"
    fi
done < "$WORK/manifest.tsv"

printf '— сверено строк: %d (accept %d, reject %d), расхождений с движком: %d\n' \
       "$total" "$accept" "$reject" "$wrong"
fail=0
[[ $total -eq $EXPECTED_ROWS ]] || { echo "✘ до движка дошло $total строк, в эталоне $EXPECTED_ROWS" >&2; fail=1; }
[[ $accept -eq $EXPECTED_ACCEPT ]] || { echo "✘ движок принял $accept, по эталону $EXPECTED_ACCEPT" >&2; fail=1; }
[[ $reject -eq $EXPECTED_REJECT ]] || { echo "✘ движок отбраковал $reject, по эталону $EXPECTED_REJECT" >&2; fail=1; }
[[ $fail -eq 0 && $wrong -eq 0 ]]
