package app.anemia.core

/**
 * Порт `Sources/LoaderCore/EngineLog.swift` — что показать пользователю, когда
 * движок умер при старте.
 *
 * На Android текст приходит не строкой из лога, а возвращённой ошибкой
 * (`xray config: … > …`): движок живёт в том же процессе, и обёртки
 * `Failed to start:` от xray-ной команды тут нет. Цепочка при та же самая,
 * поэтому правило одно на обе платформы, а не «каждой своей половине удобней».
 */
object EngineLog {
    /** Причина смерти по хвосту строк движка — ровно то, что делает macOS. */
    fun failureReason(lines: List<String>): String {
        lines.lastOrNull { it.contains("Failed to start") }?.let { return cause(it) }
        lines.lastOrNull { looksLikeFailure(it) }?.let { return it }
        return lines.lastOrNull() ?: "engine exited during startup"
    }

    /**
     * Внутренняя причина одной строки ошибки, есть в ней цепочка или нет.
     *
     * Без ` > ` текст возвращается обрезанным и не изменённым: «Failed to
     * start: boom» — это всё, что есть, и снять обёртку означало бы оставить
     * пользователя со словом без смысла.
     */
    fun cause(text: String): String {
        val chain = text.split(" > ")
            .map { trimFoundationSpaces(it) }
            .filter { it.isNotEmpty() }
        if (chain.size <= 1) return trimFoundationSpaces(text)
        return stripPackagePrefix(chain.last())
    }

    /**
     * «infra/conf: Failed to build TLS config.» → «Failed to build TLS config.»
     * путём (со слэшем) и без пробелов — это префикс Go-пакета; «listen tcp
     * 127.0.0.1:1080: bind: …» остаётся как есть.
     */
    internal fun stripPackagePrefix(text: String): String {
        val colon = text.indexOf(": ")
        if (colon < 0) return text
        val head = text.substring(0, colon)
        if (!head.contains('/') || head.contains(' ')) return text
        // Пустой хвост здесь невозможен: звено цепочки уже обрезано (см. порт на
        // Swift) — раньше эта строка только притворялась защитой.
        return text.substring(colon + 2)
    }

    /**
     * Похожа ли строка на отказ. Складка только ASCII — намеренно:
     * Foundation-овский `localizedCaseInsensitiveContains` смотрит на локаль
     * устройства, и в турецкой «FAILED» перестал бы совпадать с «failed»
     * (заглавная I с точкой). Движок пишет эти слова ASCII-английски, а
     * остальная часть строки может нести пользовательский текст — он не должен
     * влиять на выбор строки.
     */
    fun looksLikeFailure(line: String): Boolean {
        val lowered = StringBuilder(line.length)
        for (char in line) {
            val code = char.code
            lowered.append(if (code in 65..90) (code + 32).toChar() else char)
        }
        val text = lowered.toString()
        return text.contains("failed") || text.contains("invalid")
    }
}
