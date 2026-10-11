package app.anemia.data

import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.EncodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.encoder.Encoder
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel

/**
 * QR-код переноса. На iOS это один вызов `CIFilter.qrCodeGenerator()` с уровнем
 * коррекции L; здесь тот же уровень выбран явно и рисуется матрица вручную —
 * без сглаживания, как и на iOS, чтобы модули оставались квадратиками, а не
 * серой кашей.
 *
 * Отдельный файл он не ради порядка: кодирование и чтение проверяются на JVM
 * (`app/src/test/…/QrTest.kt`), а рисование — в Compose, где тест был бы тестом
 * растровой библиотеки, а не кода.
 */
object Qr {
    /** null — текст не влезает в QR-код (версия 40 — потолок, ~2953 байта). */
    fun matrix(text: String): Array<BooleanArray>? = runCatching {
        val code = Encoder.encode(text, ErrorCorrectionLevel.L, emptyMap<EncodeHintType, Any>())
        val symbol = code.matrix
        // Тихая зона добавляется здесь, а не берётся из подсказки: `Encoder`
        // значение `MARGIN` просто игнорирует (замерено на 3.5.3 — матрица
        // приходит ровно с модулями, без полей), а без белого поля вокруг
        // сканер не находит рамку кода.
        val width = symbol.width + 2 * QUIET_MODULES
        val height = symbol.height + 2 * QUIET_MODULES
        Array(height) { y ->
            BooleanArray(width) { x ->
                val inner = y - QUIET_MODULES
                val innerX = x - QUIET_MODULES
                inner in 0 until symbol.height && innerX in 0 until symbol.width &&
                    symbol.get(innerX, inner).toInt() == 1
            }
        }
    }.getOrNull()

    /**
     * Матрица обратно в текст — тем же путём, каким её прочтёт чужой сканер.
     * Это оракул теста: round-trip доказывает, что нарисованный код читается,
     * а не только «не бросил при генерации». Модули раздуваются в 8 раз —
     * детектор zxing ищет три блока по 7 модулей, и на одном пикселе на модуль
     * он прав, но так проверка ближе к живой фотографии.
     */
    fun read(matrix: Array<BooleanArray>): String? = runCatching {
        val scale = 8
        val width = matrix.first().size * scale
        val height = matrix.size * scale
        val pixels = IntArray(width * height) { index ->
            val dark = matrix[(index / width) / scale][index % width / scale]
            if (dark) DARK else LIGHT
        }
        val source = RGBLuminanceSource(width, height, pixels)
        val hints = mapOf(DecodeHintType.TRY_HARDER to true)
        MultiFormatReader().decode(BinaryBitmap(HybridBinarizer(source)), hints).text
    }.getOrNull()

    /** Ширина модуля в пикселях — те же 12, что и масштаб `CGAffineTransform` на iOS. */
    const val MODULE_PIXELS = 12

    /**
     * Матрица в пиксели растра: (строка пикселей, ширина). Вынесено из рисования
     * не для красоты — на телефоне квадрат кода оказался белым, потому что
     * `Bitmap.setPixels` вызывали с `stride = 0` и подменёнными осями, а тест
     * матрицы этого увидеть не мог: он проверял код, а не растр.
     */
    fun pixels(matrix: Array<BooleanArray>, scale: Int = MODULE_PIXELS): Pair<IntArray, Int> {
        val width = matrix.first().size * scale
        val height = matrix.size * scale
        val pixels = IntArray(width * height) { index ->
            val row = index / width
            val column = index % width
            if (matrix[row / scale][column / scale]) DARK else LIGHT
        }
        return pixels to width
    }

    private const val QUIET_MODULES = 4
    private val DARK = 0xFF000000.toInt()
    private val LIGHT = 0xFFFFFFFF.toInt()
}
