package app.anemia.data

import app.anemia.core.MaskingProfile
import app.anemia.core.ProxyProtocol
import app.anemia.core.ProxyServer
import app.anemia.core.SyncBundle
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * QR переноса: код, который нарисован, обязан читаться обратно — и читаться
 * именно как ссылка, а не как «что-то похожее». Это единственный проверка,
 * которая отделена от Compose: рисование в `ImageBitmap` тестировать нечем.
 *
 * Данные — настоящий `SyncBundle`, а не случайная строка: размер кода
 * определяется длиной ссылки, а она растёт от числа серверов.
 */
class QrTest {

    private fun bundle(servers: List<ProxyServer>) = SyncBundle(
        exportedAt = 1_760_000_000.0,
        device = "test-phone",
        servers = servers,
        subscriptions = emptyList(),
        settings = SyncBundle.Settings(maskingProfile = MaskingProfile.balanced),
    )

    private fun server(name: String) = ProxyServer(
        // Детерминированный id: `ProxyServer` по умолчанию берёт `randomUUID()`,
        // и ссылка сорока серверов длиной ~3 КБ выходит ровно на потолок QR
        // версии 40. С случайными id тест то проходил, то падал на одном и том
        // же коде — а такой «иногда красный» тест ничего не закрепляет.
        id = java.util.UUID.nameUUIDFromBytes(name.toByteArray(Charsets.UTF_8)),
        name = name,
        proto = ProxyProtocol.VLESS,
        address = "example-$name.test",
        port = 443,
        credential = "11111111-1111-1111-1111-111111111111",
    )

    @Test
    fun `ссылка переноса читается из нарисованного кода`() {
        val link = bundle(listOf(server("a"), server("b"))).link()
        val matrix = Qr.matrix(link) ?: error("код не сгенерирован для ${link.length} байт")
        assertEquals(link, Qr.read(matrix))
    }

    @Test
    fun `код квадратный и с полем вокруг`() {
        val matrix = Qr.matrix("anemia://sync/short") ?: error("нет кода")
        assertTrue(matrix.isNotEmpty())
        assertTrue(matrix.all { it.size == matrix.first().size })
        // Четыре модуля белой рамки по каждому краю: без них сканер не находит
        // координатные блоки. Проверяется ширина поля, а не «где-то бело»:
        // `Encoder` подсказку MARGIN игнорирует, и молча остаться с нулевым
        // полем было бы легко не заметить.
        val quiet = 4
        repeat(quiet) { offset ->
            assertTrue(matrix[offset].all { !it })
            assertTrue(matrix[matrix.size - 1 - offset].all { !it })
            assertTrue(matrix.all { row -> !row[offset] && !row[row.size - 1 - offset] })
        }
        // Первый модуль самого кода — тёмный угол координатного блока.
        assertTrue(matrix[quiet][quiet])
    }

    @Test
    fun `перенос из сорока серверов в QR ещё влезает`() {
        val link = bundle((1..40).map { server("s$it") }).link()
        assertNotNull("ссылка не построилась", link)
        val matrix = Qr.matrix(link)
        assertNotNull("40 серверов не должны были вывалиться из QR", matrix)
        assertEquals(link, Qr.read(matrix!!))
    }

    @Test
    fun `растр кода совпадает с матрицей, а не белый квадрат`() {
        val matrix = Qr.matrix("anemia://sync/pixels") ?: error("нет кода")
        val (pixels, width) = Qr.pixels(matrix, scale = 3)
        val height = pixels.size / width
        // Размер = модули × масштаб, и рядов ровно столько, сколько столбцов.
        assertEquals(matrix.first().size * 3, width)
        assertEquals(height, width)
        // Первый пиксель — тихая зона, белый; первый тёмный модуль кода лежит
        // на расстоянии 4 модуля × масштаб.
        assertEquals(0xFFFFFFFF.toInt(), pixels[0])
        assertEquals(0xFF000000.toInt(), pixels[4 * 3 * width + 4 * 3])
        // Каждый пиксель обязан совпадать с модулем, из которого взят: сдвиг
        // осей или stride = 0 дают белый квадрат вместо кода на экране.
        for (row in 0 until height step 17) {
            for (column in 0 until width step 13) {
                val expected = if (matrix[row / 3][column / 3]) 0xFF000000.toInt() else 0xFFFFFFFF.toInt()
                assertEquals("пиксель ($row,$column)", expected, pixels[row * width + column])
            }
        }
    }

    @Test
    fun `то, что не влезает, возвращается отказом, а не битым кодом`() {
        // Потолок QR версии 40 при L — 2953 байта; за ним `Encoder` бросает, и
        // экран обязан увидеть null и предложить файл, а не рисовать мусор.
        assertNull(Qr.matrix("x".repeat(4000)))
    }
}
