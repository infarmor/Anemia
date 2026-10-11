package app.anemia.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Карта: Kotlin-порт выборки сот и вердикта «суша или море» сверяется с
 * настоящим Swift'ом.
 *
 * Золотые файлы и сам ассет генерирует `Android/Scripts/golden-map.sh` из
 * `iOS/Anemia/MapData.swift` — сравниваются две реализации одной выборки, а не
 * два пересказа одних и тех же чисел. Сравнение побитовое: Foundation и JVM
 * печатают дроби по-разному, а сота обязана встать на своё место, а не
 * «примерно туда».
 *
 * Тест живёт в `:app` (а не рядом с остальными золотыми сверками в `:core`)
 * только потому, что ассет — ресурс приложения; фикстуры при этом лежат в
 * `core/src/test/resources/map`, как и всё остальное золото.
 */
class MapGeoTest {

    private val asset get() = resolve("src/main/assets/map.json")
    private val dots get() = resolve("../core/src/test/resources/map/dots.golden.txt")
    private val points get() = resolve("../core/src/test/resources/map/points.golden.txt")

    private fun resolve(path: String): File {
        val file = File(path)
        assertTrue("нет $path (рабочий каталог: ${File(".").absolutePath})", file.isFile)
        return file
    }

    /** Биты числом без знака: `Long.toString(16)` для отрицательных значений
     * печатает «−» и модуль, и биты 0xc058… превращаются в «-3fa7…» — тест
     * краснеет на ровно том же месте, на чём у Swift споткнулся `%016x`. */
    private fun bits(value: Double): String =
        java.lang.Long.toHexString(java.lang.Double.doubleToRawLongBits(value)).padStart(16, '0')

    private fun unhex(text: String): Double =
        java.lang.Double.longBitsToDouble(text.toULong(16).toLong())

    private val map by lazy { MapGeo.parse(asset.readText(Charsets.UTF_8)) }

    @Test
    fun `соты совпадают со Swift побитно`() {
        val cells = map.landCells
        val expected = dots.readLines().filter { it.startsWith("dot") }
        assertEquals("число сот: ", expected.size, cells.size)
        // Разбор по одной соте, а не одним списком: одна сдвинувшаяся ячейка
        // иначе покраснила бы весь вывод, и где началось — непонятно.
        for (index in cells.indices) {
            val fields = expected[index].split('\t')
            val cell = cells[index]
            assertEquals(
                "сота $index (${cell.lat}, ${cell.lon}): ",
                fields.drop(1),
                listOf(bits(cell.lat), bits(cell.lon), bits(cell.x), bits(cell.y)),
            )
        }
    }

    @Test
    fun `вердикт суша-море совпадает со Swift на пробных точках`() {
        var sea = 0
        for (line in points.readLines().filter { it.startsWith("point") }) {
            val fields = line.split('\t')
            val lat = unhex(fields[1])
            val lon = unhex(fields[2])
            val wanted = fields[3] == "1"
            if (!wanted) sea += 1
            assertEquals("точка ($lat, $lon): ", wanted, map.isLand(lat, lon))
        }
        // Прогон «всё стало сушей» или «всё стало морем»краснеет и на сравнении,
        // но без этой строки он мог бы сверять пустой список.
        assertTrue("проб на море меньше трёх — фикстура не о том", sea >= 3)
    }

    @Test
    fun `проекция держит центры стран внутри полосы`() {
        assertEquals("отношение сторон: ", 360.0 / 136.0, map.aspect, 0.0)
        assertTrue("центров стран раскидалось: ${map.centers.size}", map.centers.size >= 90)
        for ((code, center) in map.centers) {
            val x = map.projectX(center[1])
            val y = map.projectY(center[0])
            assertTrue("$code вне полосы по x: $x", x in 0.0..1.0)
            assertTrue("$code вне полосы по y: $y", y in 0.0..1.0)
        }
        assertEquals(0.0, map.projectX(-180.0), 0.0)
        assertEquals(1.0, map.projectX(180.0), 0.0)
        assertEquals(0.0, map.projectY(80.0), 0.0)
        assertEquals(1.0, map.projectY(-56.0), 0.0)
    }

    @Test
    fun `кривой ассет отказывает, а не даёт пустую карту`() {
        // Молча пустая карта — это «приложение сломалось тихо»; тот же смысл,
        // что у строгого разбора TunnelSetup.
        runCatching { MapGeo.parse("""{"latTop":80.0}""") }.exceptionOrNull()
            ?: error("пустой документ обязан был отказать")
        runCatching {
            MapGeo.parse("""{"latTop":80.0,"latBottom":-56.0,"rings":[["x"]],"centers":{}}""")
        }.exceptionOrNull() ?: error("кольцо с мусором обязано было отказать")
        runCatching { MapGeo.parse("""не json""") }.exceptionOrNull()
            ?: error("неразбираемый документ обязан был отказать")
    }
}
