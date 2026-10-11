#!/usr/bin/env bash
#
# География карты Android'а не перепечатывается руками: `iOS/Anemia/MapData.swift`
# — единственный источник береговых линий и центров стран, и скрипт компилирует
# именно его вместе с маленьким эмиттером.
#
# На выходе два файла:
#
#   app/src/main/assets/map.json                 — что читает приложение
#                          (геометрия, кольца, центры стран);
#   core/src/test/resources/map/dots.golden.txt  — соты, которые Swift насчитал
#                          своим кодом, и с ними сверяется Kotlin-порт выборки.
#
# Числа в золоте — биты IEEE-754, а не десятичные строки: Foundation и JVM
# печатают дробями по-разному (тот же `5e-322` против `4.9E-324`), а побитовое
# сравнение не оставляет запятой ни в каком смысле.
#
#   bash Android/Scripts/golden-map.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/iOS/Anemia/MapData.swift"
ASSET="$ROOT/Android/app/src/main/assets/map.json"
FIXTURE="$ROOT/Android/core/src/test/resources/map/dots.golden.txt"
POINTS="$ROOT/Android/core/src/test/resources/map/points.golden.txt"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[[ -f "$SRC" ]] || { echo "✗ нет $SRC" >&2; exit 1; }

# Эмиттер видит те же имена, что и экран: файл компилируется одним модулем с
# `MapData.swift`. Приватные массивы кольца читаются через `Mirror` — иначе
# пришлось бы править iOS-исходник ради Android-прогона.
cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

func hex(_ value: Double) -> String { String(format: "%016llx", value.bitPattern) }

func flat(_ ring: Ring) -> [Double] {
    var lons: [Double] = [], lats: [Double] = []
    for child in Mirror(reflecting: ring).children {
        switch child.label {
        case "lons": lons = child.value as! [Double]
        case "lats": lats = child.value as! [Double]
        default: break
        }
    }
    precondition(lons.count == lats.count && !lons.isEmpty, "кольцо прочиталось криво")
    var out: [Double] = []
    for index in lons.indices { out.append(lons[index]); out.append(lats[index]) }
    return out
}

var json = "{"
json += "\"latTop\":\(MapGeometry.latTop),\"latBottom\":\(MapGeometry.latBottom),"
json += "\"rings\":[" + Coastline.rings.map { ring in
    "[" + flat(ring).map { String(describing: $0) }.joined(separator: ",") + "]"
}.joined(separator: ",") + "],"
json += "\"centers\":{" + CountryGeo.centers.keys.sorted().map { code in
    let center = CountryGeo.centers[code]!
    return "\"\(code)\":[\(center.lat),\(center.lon)]"
}.joined(separator: ",") + "}}"
print(json)

for cell in WorldDots.cells {
    print("dot\t\(hex(cell.lat))\t\(hex(cell.lon))\t\(hex(cell.x))\t\(hex(cell.y))")
}

// Вердикт «суша или море» для заранее выбранных точек — те же чётно-нечётные
// переключения, что и в выборке, но посчитанные настоящим Swift'ом: вручную
// такие точки выбирать нельзя (окараулить, какое именно кольцо где накрывает,
// по памяти о берегах нельзя).
let probes: [(Double, Double)] = [
    (58.8, -90.0), (42.0, 51.0), (44.0, 34.0), (36.0, 18.0), (45.5, -83.0),
    (55.7, 37.6), (51.1, 71.4), (30.0, 31.2), (48.85, 2.35), (40.7, -74.0),
    (-33.8, 151.2), (-22.9, -43.2), (-33.9, 18.4), (35.7, 139.7), (19.0, 72.8),
    (-1.3, 36.8), (19.4, -99.1), (21.3, -157.9), (64.1, -21.9), (61.2, -149.9),
    (-54.8, -68.3), (-70.0, 0.0), (-30.0, -20.0), (56.0, 3.0), (59.0, 19.0),
    (27.0, 51.0), (22.0, 38.0), (15.0, 89.0), (78.0, 15.0), (-45.0, 170.0),
    (0.0, 0.0), (70.0, -45.0), (43.0, 87.0), (-5.0, 120.0), (36.5, -6.0),
]
for probe in probes {
    var inside = false
    for ring in Coastline.rings where ring.contains(lat: probe.0, lon: probe.1) { inside.toggle() }
    print("point\t\(hex(probe.0))\t\(hex(probe.1))\t\(inside ? 1 : 0)")
}
SWIFT

xcrun swiftc -Onone "$SRC" "$WORK/main.swift" -o "$WORK/emit" 2>&1 | grep -v '^$' | head -20 || true
[[ -x "$WORK/emit" ]] || { echo "✗ эмиттер не собрался" >&2; exit 1; }

mkdir -p "$(dirname "$ASSET")" "$(dirname "$FIXTURE")"
# Всё в один поток и раскладывается по префиксу строк: JSON — первая строка,
# соты — все строки `dot`.
"$WORK/emit" > "$WORK/all.txt"
head -1 "$WORK/all.txt" > "$WORK/map.json"
grep '^dot' "$WORK/all.txt" > "$WORK/dots.txt"
grep '^point' "$WORK/all.txt" > "$WORK/points.txt"

dots=$(grep -c '^dot' "$WORK/dots.txt" || true)
points=$(grep -c '^point' "$WORK/points.txt" || true)
if [[ "$points" -lt 30 ]]; then
    echo "✗ вердиктов точки вышло $points — эмиттер не дошёл до проб" >&2
    exit 1
fi
if [[ "$dots" -lt 3000 ]]; then
    echo "✗ сот вышло $dots — меньше трёх тысяч значит, что выборка не дошла" >&2
    exit 1
fi
# Документ обязан разбираться: кривой JSON — это пустая карта на устройстве и
# зелёный прогон здесь, если не проверить.
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['rings'] and d['centers'], 'пусто'" \
    "$WORK/map.json" || { echo "✗ map.json не читается как JSON" >&2; exit 1; }

cp "$WORK/map.json" "$ASSET"
cp "$WORK/dots.txt" "$FIXTURE"
cp "$WORK/points.txt" "$POINTS"
echo "✓ ${ASSET#$ROOT/} — $(wc -c < "$ASSET") байт, колец: $(grep -o 'Ring(\[' "$SRC" | wc -l | tr -d ' ')"
echo "✓ ${FIXTURE#$ROOT/} — сот: $dots, ${POINTS#$ROOT/} — вердиктов: $points"
echo "  центров стран: $(python3 -c "
import json,sys
print(len(json.load(open(sys.argv[1]))['centers']))" "$ASSET")"
