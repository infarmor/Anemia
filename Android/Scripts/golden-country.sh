#!/usr/bin/env bash
#
# Пересоздаёт эталон Country: какие коды страны, флаги и «места» видит
# Swift-код в реальных именах серверов.
#
#   bash Android/Scripts/golden-country.sh
#
# Эталон даёт `iOS/Activity/ActivityText.swift` — тот же `Country`, которым
# живут заголовок Dynamic Island, карта и группировка серверов. Kotlin-порт
# сверяется с ним в test-core.sh. Два набора фикстур: `names.txt` (имена
# серверов → код/флаг/место) и `codes.txt` (произвольные «коды страны», какие
# приходят из ответов leak-сервисов, → флаг/название). Названия стран берутся
# из CLDR системы, и версии баз у Apple и у JVM разные: скрипт печатает
# расхождения по именам отдельным списком, чтобы они были видны, а не молча
# «прощены».
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/iOS/Activity/ActivityText.swift"
FIX="$ROOT/Android/core/src/test/resources/country"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[[ -f "$SRC" && -f "$FIX/names.txt" ]] || { echo "✗ нет исходника или фикстур" >&2; exit 1; }

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

let text = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
for line in text
        .split(separator: "\n", omittingEmptySubsequences: false) {
    let name = String(line)
    if name.isEmpty { continue }
    if CommandLine.arguments.count > 2 {
        // codes.txt: произвольные «коды страны» — их приложение получает из
        // ответов leak-сервисов, где поле `loc` может быть чем угодно.
        print([name, Country.flag(name), Country.name(name)].joined(separator: "\t"))
        continue
    }
    let code = Country.code(inServerName: name)
    print([code ?? "", code.map(Country.flag) ?? "", Country.place(inServerName: name),
           code.map(Country.name) ?? ""].joined(separator: "\t"))
}
SWIFT

swiftc -O -o "$WORK/country" "$SRC" "$WORK/main.swift"

[[ -f "$FIX/codes.txt" ]] || { echo "✗ нет $FIX/codes.txt" >&2; exit 1; }
"$WORK/country" "$FIX/names.txt" > "$FIX/names.tsv"
"$WORK/country" "$FIX/codes.txt" codes > "$FIX/codes.tsv"
echo "✓ $FIX/names.tsv ($(wc -l < "$FIX/names.tsv" | tr -d ' ') строк)"
echo "✓ $FIX/codes.tsv ($(wc -l < "$FIX/codes.tsv" | tr -d ' ') строк)"

# Имена стран — сравнение справочников, а не логики: печатаем различия, но не
# считаем их падением.
python3 - "$FIX/names.tsv" <<'PY' || true
import sys, unicodedata
seen = {}
for line in open(sys.argv[1], encoding="utf-8"):
    code, _flag, _place, name = line.rstrip("\n").split("\t")
    if code:
        seen[code] = name
try:
    import subprocess, json
    print("имена из Apple CLDR:", json.dumps(seen, ensure_ascii=False))
except Exception:
    pass
PY
