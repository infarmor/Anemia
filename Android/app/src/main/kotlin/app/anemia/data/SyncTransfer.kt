package app.anemia.data

import android.content.Context
import android.os.Build
import app.anemia.core.PersistedState
import app.anemia.core.SyncBundle
import app.anemia.core.SyncDecodeException
import app.anemia.core.trimSpaceLike

/**
 * Перенос между устройствами — порт `iOS/Anemia/Transfer.swift`: тот же
 * `SyncBundle` (файл `.anemia`, ссылка `anemia://sync/`, QR), те же тексты
 * отказа и то же «что добавится, а что уже есть».
 *
 * Формат здесь не изобретается: `core/…/SyncBundle.kt` сверяется с Swift
 * тридцатью пятью кейсами, а `Scripts/verify-sync.sh` перечитывает ссылку
 * Kotlin'а настоящим Swift-декодером. Экран только носит этот документ.
 */
object SyncTransfer {
    /**
     * Что уедет с этого устройства. Серверы — только добавленные руками:
     * подписочные приедут вместе со своей подпиской и загрузятся заново,
     * иначе перенос утащил бы чужой снимок панелей.
     */
    fun bundle(state: PersistedState, adBlock: Boolean, device: String = deviceName()): SyncBundle {
        val bundle = SyncBundle(
            exportedAt = System.currentTimeMillis() / 1000.0,
            device = device,
            servers = state.servers,
            subscriptions = state.subscriptions.map {
                SyncBundle.SubscriptionEntry(name = it.name, url = it.url)
            },
            settings = SyncBundle.Settings(
                maskingProfile = state.maskingProfile,
                killSwitchEnabled = state.killSwitchEnabled,
                splitTunnel = state.splitTunnel,
                learnedMasking = state.learnedMasking.ifEmpty { null },
                subscriptionAutoRefresh = state.subscriptionAutoRefresh,
            ),
        )
        // `adBlock` на Android живёт в настройках экрана, а не в `state.json`,
        // и уезжает тем же полем, что на iOS (см. `ServerStore.syncBundle`).
        return bundle.copy(settings = bundle.settings?.copy(adBlock = adBlock))
    }

    /**
     * Принятый текст: ссылка переноса или JSON файла. null — это вообще не
     * перенос (тогда строку стоит пробовать как ссылку сервера). Бросает
     * [SyncDecodeException] — это похоже на перенос, но не читается, и молча
     * принять такое за ссылку было бы хуже отказа.
     */
    fun incoming(text: String): SyncBundle? {
        if (!SyncBundle.looksLikeBundle(text)) return null
        return SyncBundle.decode(text)
    }

    /** Тот же текст отказа, что показывает шторка iOS. */
    fun failure(error: Throwable): String = when {
        error is SyncDecodeException && error.kind == "newerVersion" ->
            "Данные из более новой версии Anemia — обновите приложение."
        else -> "Не удалось прочитать данные: файл или QR-код повреждён."
    }

    /** Имя устройства в бандле — аналог `UIDevice.current.name`. */
    fun deviceName(): String = Build.MODEL?.takeIf { it.isNotBlank() } ?: "Android"

    /**
     * Текст из чужого URI: файл переноса, который человек выбрал в
     * `OpenDocument` или прислал приложением. Пустой ответ — не прочитали.
     * Потолок в 8 МБ тот же, что у загрузки подписки: память процесса не
     * резиновая, а «файл переноса» размером с фильм — это не перенос.
     *
     * Читать надо с подсчётом байт, а не `readBytes()`: потолок проверяется по
     * мере чтения, иначе чужое «Поделиться» архивом или видео выделило бы память
     * под весь файл целиком — на главной нити и с нулевым шансом, что человек
     * увидит причину отказа.
     */
    fun textOf(context: Context, uri: android.net.Uri): String? = runCatching {
        context.contentResolver.openInputStream(uri)?.use { input ->
            val out = java.io.ByteArrayOutputStream(64 * 1024)
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                out.write(buffer, 0, read)
                if (out.size() > MAX_BUNDLE_BYTES) return null
            }
            String(out.toByteArray(), Charsets.UTF_8)
        }
    }.getOrNull()

    /** Записать бандль в выбранный человеком файл. Текст — причина отказа. */
    fun write(context: Context, uri: android.net.Uri, bundle: SyncBundle): String? {
        val bytes = bundle.fileData().toByteArray(Charsets.UTF_8)
        return runCatching {
            // `wt` — создать и усечь: без права на запись SAF вернёт null, и
            // молча «сохранённый» файл был бы хуже честной ошибки.
            val stream = context.contentResolver.openOutputStream(uri, "wt")
                ?: throw java.io.IOException("нет доступа на запись")
            stream.use { it.write(bytes) }
        }.exceptionOrNull()?.let { it.message ?: "Файл не записан" }
    }

    /**
     * Файл для «Отправить» — в кэше и через FileProvider: наружу отдаётся
     * одноразовое право чтения, а не world-readable копия с приватными ключами
     * серверов.
     */
    fun shareFile(context: Context, bundle: SyncBundle): android.net.Uri? {
        val file = java.io.File(context.cacheDir, FILE_NAME)
        return runCatching {
            file.writeText(bundle.fileData(), Charsets.UTF_8)
            androidx.core.content.FileProvider.getUriForFile(
                context, context.packageName + ".files", file,
            )
        }.getOrNull()
    }

    const val FILE_NAME = "Anemia.anemia"

    /**
     * Тот же вид url, что у слияния в `SyncBundle.normalizedUrl`: «эта подписка
     * уже есть» сверяется без регистра, пробелов Foundation и завершающего
     * слэша. Два разных правила для одного сравнения — это две подписки на
     * одну панель.
     */
    fun normalized(url: String): String = trimSpaceLike(url).lowercase().trim('/')

    private const val MAX_BUNDLE_BYTES = 8 * 1024 * 1024
}
