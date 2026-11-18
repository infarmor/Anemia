package app.anemia.vpn

import app.anemia.core.EngineLog
import app.anemia.core.Json

/**
 * Kotlin-лицо Go-движка: Xray-core и AmneziaWG в одном рантайме, один за раз.
 * Порт `iOS/AnemiaTunnel/Engine.swift`; между ним и `libanemia.so` лежит
 * JNI-шим (`Android/engine/jni/anemia_jni.c`), потому что Go экспортирует
 * чистые C-функции.
 *
 * Процесс туннеля отдельный (`android:process=":vpn"`), поэтому здесь всё
 * статическое: один движок, одни счётчики.
 */
object Engine {
    class Failure(message: String) : Exception(message)

    /** `AnemiaCheckActive` без символа в `libanemia.so`; см. [checkActive]. */
    private const val NO_SYMBOL = -3L

    /** Адрес проверки не перешёл через JNI; см. [checkActive]. */
    private const val NO_ARGUMENT = -4L


    /** Ответ `AnemiaStatus()`. Поля читаются по одному — см. комментарий ниже. */
    data class Status(
        val engine: String,
        val uptime: Double,
        val up: Long,
        val down: Long,
        /** Время последнего рукопожатия AmneziaWG, 0 до первого. */
        val handshake: Long,
        val heap: Long,
        val sys: Long,
        val goroutines: Int,
        /** Ключей, которых в ответе не оказалось. */
        val missingKeys: List<String> = emptyList(),
    ) {
        companion object {
            val KEYS = listOf("engine", "uptime", "up", "down", "handshake", "heap", "sys", "goroutines")
        }
    }

    /** false, если библиотеку не удалось поднять — приложение тогда живёт без туннеля. */
    val available: Boolean by lazy {
        try {
            System.loadLibrary("anemia_jni")
            loadLibrary()
        } catch (error: UnsatisfiedLinkError) {
            false
        }
    }

    private external fun loadLibrary(): Boolean
    private external fun nativeStartXray(config: String, fd: Int): String?
    private external fun nativeStartAwg(uapi: String, fd: Int): String?
    private external fun nativeStop()
    private external fun nativeNetworkChanged()
    private external fun nativeStatus(): String?
    private external fun nativeVersion(): String?
    private external fun nativeSetMemoryLimit(bytes: Long)
    private external fun nativeSetLogDirectory(directory: String): String?

    /**
     * Конфиг Xray — текстом, как на iOS; движок сам дублирует дескриптор.
     * Проверка `available` здесь не косметика: без неё `UnsatisfiedLinkError`
     * — это `Error`, а `openTunnel` ловит `Exception`, так что процесс гиб бы
     * с уже поднятым туннелем и без единой строчки пользователю.
     */
    fun startXray(config: String, tunnelFd: Int) {
        if (!available) error("движок не загружен")
        fail(nativeStartXray(config, tunnelFd))
    }

    fun startAwg(uapi: String, tunnelFd: Int) {
        if (!available) error("движок не загружен")
        fail(nativeStartAwg(uapi, tunnelFd))
    }

    /**
     * Отказ движка наружу так, как его показывает macOS: Go-ошибка — это
     * цепочка «внешняя обёртка > … > настоящая причина», и попросить
     * «перезапустить xray» по «failed to build stream settings» нельзя.
     * Цель — последнее звено; полный текст остаётся в логе, потому что
     * внешние звенья иногда единственное, что отличает одну поломку от другой.
     */
    private fun fail(message: String?) {
        if (message == null) return
        android.util.Log.w("Anemia", "engine start failed: $message")
        throw Failure(EngineLog.cause(message))
    }

    fun stop() {
        if (available) nativeStop()
    }

    /** Wi-Fi ↔ мобильная сеть: AmneziaWG перепривязывает сокеты. */
    fun networkChanged() {
        if (available) nativeNetworkChanged()
    }

    private external fun nativeCheckActive(target: String, timeoutMs: Int): Long
    private external fun nativeFetch(url: String, timeoutMs: Int, maxBytes: Int): String?
    private external fun nativeProbe(requests: String): String?

    /** Outbound-only instances in the application process, independent of the active VPN. */
    fun probe(requests: String): String? {
        if (!available) return null
        return try {
            nativeProbe(requests)
        } catch (_: UnsatisfiedLinkError) {
            null
        }
    }

    /**
     * Один настоящий GET через живое соединение, тот же `AnemiaCheckActive`,
     * что вызывает iOS: сервер может отвечать на рукопожатие и не пропускать
     * трафик — видно это только запросом наружу.
     *
     * null — «померить не удалось»: Go отвечает -1 (запрос не прошёл), -2 (Xray
     * не запущен) и -3 (символа нет, т. е. `libanemia.so` старше этой обёртки).
     * Первые два на iOS тоже провал здоровья, и третий сводится к ним же: если
     * туннель «подключён», а проверить его нечем, это не «всё в порядке».
     * Отличие -3 от -1 остаётся в логе — молча переключаться из-за кривой
     * сборки было бы нечем объяснить. -4 — отказ того же рода, но причина в
     * переходе строки через JNI: искать её надо в шейме, а не в сборке движка,
     * поэтому одна строчка лога на оба случая водила бы человека не туда.
     */
    fun checkActive(target: String, timeoutMs: Int): Long? {
        if (!available) return null
        val ms = nativeCheckActive(target, timeoutMs)
        when (ms) {
            NO_SYMBOL -> android.util.Log.w("Anemia", "AnemiaCheckActive нет в libanemia.so")
            NO_ARGUMENT -> android.util.Log.w("Anemia", "адрес проверки не передался в движок")
        }
        return if (ms > 0) ms else null
    }

    /** Ответ `AnemiaFetch`: тело, байты и время; `error` — если запрос не вышел. */
    data class Fetch(val ms: Long, val bytes: Long, val body: String, val error: String?) {
        val ok: Boolean get() = error == null && body.isNotEmpty()
    }

    /**
     * Один GET сквозь поднятый туннель — и ответ обратно. Нужен потому, что
     * сокет самого приложения идёт *мимо* VPN: `ConfigApplier` выносит его UID
     * (`addDisallowedApplication`), а привязаться к сети туннеля система не
     * даёт (замерено на устройстве: `Binding socket to network N failed:
     * EPERM` и с `allNetworks`, и с живой заявкой). Смотреть «что видят сайты»
     * поэтому может только движок.
     *
     * null — движок не запущен, ответа нет, или `AnemiaFetch` отсутствует в
     * `libanemia.so`: старый `.so` обязан оставлять туннель рабочим, а экран
     * утечек — честно Saying «не измерено», а не выдумывать адрес.
     */
    fun fetch(url: String, timeoutMs: Int = 12_000, maxBytes: Int = 16 * 1024): Fetch? {
        if (!available) return null
        // `UnsatisfiedLinkError` — это `Error`, а ловить его должен именно здесь:
        // `libanemia.so` из старой сборки не имеет символа, а процесс туннеля
        // из-за проверки утечек падать не обязан.
        val answer = try {
            nativeFetch(url, timeoutMs, maxBytes)
        } catch (error: UnsatisfiedLinkError) {
            android.util.Log.w("Anemia", "nativeFetch не найден в шейме: ${error.message}")
            return null
        } ?: run {
            android.util.Log.w("Anemia", "AnemiaFetch нет в libanemia.so")
            return null
        }
        if (answer.isEmpty()) return null
        val root = runCatching { Json.parse(answer) }.getOrNull() as? Map<*, *> ?: return null
        return Fetch(
            ms = (root["ms"] as? Double)?.toLong() ?: 0L,
            bytes = (root["bytes"] as? Double)?.toLong() ?: 0L,
            body = root["body"] as? String ?: "",
            error = root["error"] as? String,
        )
    }

    fun setMemoryLimit(bytes: Long) {
        if (available) nativeSetMemoryLimit(bytes)
    }

    /** Свой `engine.log` (и `crash.log` на панике Go) в каталоге процесса. */
    fun setLogDirectory(directory: String) {
        if (available) check(nativeSetLogDirectory(directory))
    }

    val version: String get() = if (available) nativeVersion() ?: "?" else "нет libanemia"

    /**
     * Поле за полем, а не «весь документ или nil»: переименованный ключ в
     * ответе движка иначе превращался в вечные нули в интерфейсе — на iOS это
     * уже случалось (см. `Status.init(from:)`).
     *
     * Числа приходят из JSON двойными: `heap` и `sys` — байты, и выше 9 ПБ
     * точность теряется, что для счётчиков неважно.
     */
    val status: Status?
        get() {
            if (!available) return null
            val json = nativeStatus() ?: return null
            val root = runCatching { Json.parse(json) }.getOrNull() as? Map<*, *> ?: return null
            fun text(key: String) = Json.string(root[key])
            fun whole(key: String) = (root[key] as? Double)?.toLong()
            fun count(key: String) = (root[key] as? Double)?.toInt()
            val missing = Status.KEYS.filter { key ->
                root[key] == null || (key != "engine" && whole(key) == null && count(key) == null)
            }
            if (missing.size == Status.KEYS.size) return null
            return Status(
                engine = text("engine") ?: "?",
                uptime = (root["uptime"] as? Double) ?: 0.0,
                up = whole("up") ?: 0L,
                down = whole("down") ?: 0L,
                handshake = whole("handshake") ?: 0L,
                heap = whole("heap") ?: 0L,
                sys = whole("sys") ?: 0L,
                goroutines = count("goroutines") ?: 0,
                missingKeys = missing,
            )
        }

    private fun check(message: String?) {
        if (message != null) throw Failure(message)
    }
}
