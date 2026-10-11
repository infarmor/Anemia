package app.anemia.data

import android.content.SharedPreferences
import app.anemia.core.SubscriptionInfo
import org.json.JSONException
import org.json.JSONObject
import java.util.UUID

/**
 * Заголовки панели между запусками: имя, остаток трафика, срок и
 * `profile-update-interval`. На macOS и iOS они лежат в UserDefaults (` subscriptionInfo`),
 * здесь — в отдельных предпочтениях, а не в `state.json`: формат состояния
 * общий со Swift, и лишний ключ в нём означал бы расхождение контракта ради
 * данных, которые Swift всё равно не читает.
 *
 * Между запусками их держать обязанно: автообновление ходит к панели только
 * когда той пора, и без этого остаток и срок пропадали бы из строки после
 * каждой перезапуска, пока панель ещё не созрела. Интервал без этого тоже
 * терялся бы: панель, просящая сутки, получала бы дефолтные шесть часов.
 */
class PanelStore(private val prefs: SharedPreferences) {

    /** Кривой кэш — это пустой кэш, а не испорченный запуск: список серверов
     * живёт в состоянии, здесь только то, что о панели рассказала её ответ. */
    fun load(): Map<UUID, SubscriptionInfo> {
        val text = prefs.getString(KEY, null) ?: return emptyMap()
        val out = HashMap<UUID, SubscriptionInfo>()
        val root = try {
            JSONObject(text)
        } catch (error: JSONException) {
            return emptyMap()
        }
        for (key in root.keys()) {
            val id = parseId(key) ?: continue
            val entry = root.optJSONObject(key) ?: continue
            out[id] = SubscriptionInfo(
                title = entry.optString("title").takeIf { it.isNotEmpty() },
                uploaded = entry.optLongOrNull("uploaded"),
                downloaded = entry.optLongOrNull("downloaded"),
                total = entry.optLongOrNull("total"),
                expires = entry.optLongOrNull("expires"),
                updateInterval = entry.optDoubleOrNull("updateInterval"),
                supportUrl = entry.optString("supportUrl").takeIf { it.isNotEmpty() },
                webPageUrl = entry.optString("webPageUrl").takeIf { it.isNotEmpty() },
                announcement = entry.optString("announcement").takeIf { it.isNotEmpty() },
            )
        }
        return out
    }

    /** Пишется целиком: карта маленькая, а partial-запись переживала бы сбой
     * между двумя удалениями подписки. */
    fun save(infos: Map<UUID, SubscriptionInfo>) {
        val root = JSONObject()
        for ((id, info) in infos) {
            val entry = JSONObject()
            info.title?.let { entry.put("title", it) }
            entry.putNumber("uploaded", info.uploaded)
            entry.putNumber("downloaded", info.downloaded)
            entry.putNumber("total", info.total)
            entry.putNumber("expires", info.expires)
            entry.putNumber("updateInterval", info.updateInterval)
            info.supportUrl?.let { entry.put("supportUrl", it) }
            info.webPageUrl?.let { entry.put("webPageUrl", it) }
            info.announcement?.let { entry.put("announcement", it) }
            root.put(id.toString().uppercase(), entry)
        }
        prefs.edit().putString(KEY, root.toString()).apply()
    }

    private fun JSONObject.optLongOrNull(name: String): Long? =
        (opt(name) as? Number)?.toLong()

    private fun JSONObject.optDoubleOrNull(name: String): Double? =
        (opt(name) as? Number)?.toDouble()?.takeIf { it.isFinite() }

    /**
     * `JSONObject.put(String, double)` бросает `JSONException` на NaN и ∞, а
     * вызов приходит из фонового потока загрузки — то есть панель с
     * `profile-update-interval: 1e400` убила бы приложение вместо того, чтобы
     * испортить кэш. Нули и прочая ерунда из чужого файла сюда не доходят:
     * читатели выше принимают только `Number`.
     */
    private fun JSONObject.putNumber(name: String, value: Number?) {
        if (value is Double && !value.isFinite()) return
        if (value != null) put(name, value)
    }

    /** Тот же отказ от чужого формата, что в `State.UUID_PATTERN`:
     * `UUID.fromString` на JVM разбирает «0-0-0-0-0», Foundation — нет. */
    private fun parseId(text: String): UUID? =
        if (UUID_PATTERN.matches(text)) UUID.fromString(text) else null

    companion object {
        private const val KEY = "panels"
        private val UUID_PATTERN =
            Regex("[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
    }
}
