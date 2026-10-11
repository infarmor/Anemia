package app.anemia.ui

/**
 * Русское склонение счётчика: 1 сервер, 2 сервера, 5 серверов. Десятки
 * 11–14 — родительный множественный, как в «11 серверов», а 21 — снова
 * «сервер»: единица старшего разряда не значима.
 *
 * На macOS и iOS этого файла нет: их интерфейсы англоязычные, там единственное
 * и множественное число различаются только окончанием «s».
 */
internal fun counted(count: Int, one: String, few: String, many: String): String {
    val tail = if (count % 100 in 11..14) many else when (count % 10) {
        1 -> one
        2, 3, 4 -> few
        else -> many
    }
    return "$count $tail"
}
