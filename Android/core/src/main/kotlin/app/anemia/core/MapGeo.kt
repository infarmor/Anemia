package app.anemia.core

/**
 * География карты — порт `iOS/Anemia/MapData.swift`. Береговые линии и центры
 * стран приходят ассетом (`assets/map.json`), который генерируется из того же
 * Swift-файла скриптом `Scripts/golden-map.sh`, так что чисел, переписанных
 * руками, здесь нет.
 *
 * Портится только выборка сот: тот же сотовый шаг в 2°, те же шестьдесят восемь
 * рядов, то же чётно-нечётное правило по кольцам. Порядок арифметики сохранён
 * буквально — `latTop - 1 - row * 2` и `(lon + 180) / 360` записаны как у
 * Swift, иначе последнее деление разошлось бы на пол-ультимы и сота встала бы
 * рядом, но не на месте. Проверяется это побитно: `dots.golden.txt`.
 */
class MapGeo private constructor(
    val latTop: Double,
    val latBottom: Double,
    private val rings: List<Ring>,
    /** Код страны → (lat, lon). */
    val centers: Map<String, DoubleArray>,
) {
    /** Отношение сторон карты: 360° на полосу обитаемых широт. */
    val aspect: Double get() = 360.0 / (latTop - latBottom)

    /** Нормализованные 0…1 внутри прямоугольника карты. */
    fun projectX(lon: Double): Double = (lon + 180) / 360
    fun projectY(lat: Double): Double = (latTop - lat) / (latTop - latBottom)

    /**
     * Суша ли это точка — то же чётно-нечётное переключение по кольцам, что и в
     * выборке сот. Экрану нужно, чтобы тычок пальцем в море не выбирал страну, а
     * сверяется это золотом: какие именно кольца где накрывают, по памяти о
     * берегах не угадать.
     */
    fun isLand(lat: Double, lon: Double): Boolean {
        var inside = false
        for (ring in rings) if (ring.contains(lat, lon)) inside = !inside
        return inside
    }

    /** Суша: центры ячеек сотовой сетки. Считается один раз на экземпляр. */
    val landCells: List<MapCell> by lazy { sampleCells() }

    private fun sampleCells(): List<MapCell> {
        val out = ArrayList<MapCell>()
        val rows = ((latTop - latBottom) / 2).toInt()
        for (row in 0 until rows) {
            val lat = latTop - 1 - row * 2.0
            val shift = if (row % 2 == 0) 0.0 else 1.0
            for (col in 0 until 180) {
                val lon = -179 + col * 2.0 + shift
                if (lon >= 180) continue
                var inside = false
                for (ring in rings) {
                    // Чётно-нечётно по всем кольцам: внутренние моря — отдельные
                    // кольца, и они вырезают дыры тем же правилом.
                    if (ring.contains(lat, lon)) inside = !inside
                }
                if (!inside) continue
                out.add(MapCell(lat, lon, (lon + 180) / 360, (latTop - lat) / (latTop - latBottom)))
            }
        }
        return out
    }

    companion object {
        /** Число из JSON. Читатель `Json` даёт `Double`, а строка с цифрами — не
         * число: принять её значило бы молча сдвинуть соту на карте. */
        private fun real(value: Any?): Double? = value as? Double

        /** Отказ здесь — не «пустая карта», а сломанная сборка: ассет лежит в
         * APK и обязан читаться. */
        fun parse(text: String): MapGeo {
            val root = Json.parse(text) as? Map<*, *>
                ?: throw IllegalArgumentException("map.json: не объект")
            val latTop = real(root["latTop"]) ?: throw IllegalArgumentException("map.json: latTop")
            val latBottom = real(root["latBottom"]) ?: throw IllegalArgumentException("map.json: latBottom")
            val rings = (root["rings"] as? List<*> ?: emptyList<Any?>()).map { raw ->
                val numbers = raw as? List<*> ?: throw IllegalArgumentException("map.json: кольцо не список")
                Ring(numbers.map { real(it) ?: throw IllegalArgumentException("map.json: кольцо с числом-мусором") })
            }
            val centerValues = root["centers"] as? Map<*, *>
                ?: throw IllegalArgumentException("map.json: centers")
            val centers = LinkedHashMap<String, DoubleArray>()
            for ((key, value) in centerValues) {
                val code = key as? String ?: continue
                val pair = value as? List<*> ?: continue
                val lat = pair.getOrNull(0)?.let { real(it) } ?: continue
                val lon = pair.getOrNull(1)?.let { real(it) } ?: continue
                centers[code] = doubleArrayOf(lat, lon)
            }
            return MapGeo(latTop, latBottom, rings, centers)
        }
    }
}

/** Одна сота: её координаты и нормализованное место на карте. */
data class MapCell(val lat: Double, val lon: Double, val x: Double, val y: Double)

/**
 * Замкнутое кольцо берегов: [lon, lat, …] плоским списком, bounding box и
 * тест «точка внутри» по чётно-нечётному правилу — дословно `Ring` из iOS.
 */
class Ring(flat: List<Double>) {
    private val lons = ArrayList<Double>((flat.size + 1) / 2)
    private val lats = ArrayList<Double>((flat.size + 1) / 2)
    private val minLat: Double
    private val maxLat: Double
    private val minLon: Double
    private val maxLon: Double

    init {
        var index = 0
        while (index + 1 < flat.size) {
            lons.add(flat[index]); lats.add(flat[index + 1]); index += 2
        }
        minLat = lats.minOrNull() ?: 0.0
        maxLat = lats.maxOrNull() ?: 0.0
        minLon = lons.minOrNull() ?: 0.0
        maxLon = lons.maxOrNull() ?: 0.0
    }

    fun contains(lat: Double, lon: Double): Boolean {
        if (lat < minLat || lat > maxLat || lon < minLon || lon > maxLon) return false
        var inside = false
        var j = lats.size - 1
        for (i in lats.indices) {
            if ((lats[i] > lat) != (lats[j] > lat)) {
                val crossLon = (lons[j] - lons[i]) * (lat - lats[i]) / (lats[j] - lats[i]) + lons[i]
                if (lon < crossLon) inside = !inside
            }
            j = i
        }
        return inside
    }
}
