package app.anemia.data

import app.anemia.core.Json
import app.anemia.core.MaskingProfile
import app.anemia.core.ProxyServer
import app.anemia.core.SplitTunnelRules
import app.anemia.core.StateCodec

/**
 * Что должно запуститься — порт `TunnelSetup` из `iOS/Shared/TunnelMessage.swift`.
 *
 * На iOS это JSON в `providerConfiguration`: расширение может стартовать и без
 * приложения. Здесь тот же документ уезжает в extras интента, и тоже моделью
 * сервера, а не текстом ссылки: сервер мог прийти из подписки, где ссылки как
 * строки уже нет, а повторный разбор ссылки на каждом подключении ещё и
 * менял бы ему `id` (на нём держатся выученное маскирование и история проб).
 *
 * Форма JSON — своя, межплатформенного формата у этого сообщения нет (Swift
 * пишет его `JSONEncoder`'ом для себя).
 */
data class TunnelSetup(
    val server: ProxyServer,
    val masking: MaskingProfile = MaskingProfile.balanced,
    val splitTunnel: SplitTunnelRules? = null,
    val adBlock: Boolean = false,
) {
    fun toJson(): String = Json.write(
        mapOf(
            "server" to Json.parse(StateCodec.encode(server)),
            "masking" to masking.name,
            "splitTunnel" to splitTunnel?.let {
                mapOf("enabled" to it.enabled, "entries" to it.entries)
            },
            "adBlock" to adBlock,
        ),
    )

    companion object {
        /**
         * null — сообщение не читается целиком. Строго как Swift: там
         * `JSONDecoder` на поле неверного типа роняет весь документ, и
         * подключение отказывает громко; молча уступить место «без обхода» или
         * «balanced» значило бы, что сайты, которые просили пустить мимо VPN,
         * уехали в туннель, а профиль маскирования сменился сам.
         */
        fun fromJson(text: String?): TunnelSetup? {
            val root = text?.let { runCatching { Json.parse(it) }.getOrNull() } as? Map<*, *> ?: return null
            val server = runCatching { StateCodec.server(root["server"]) }.getOrNull() ?: return null
            val masking = when (val value = root["masking"]) {
                null -> MaskingProfile.balanced
                else -> MaskingProfile.of(Json.string(value)) ?: return null
            }
            val bypass = when (val value = root["splitTunnel"]) {
                null -> null
                else -> {
                    val rules = value as? Map<*, *> ?: return null
                    val enabled = if (rules["enabled"] == null) true else Json.boolean(rules["enabled"]) ?: return null
                    val entries = rules["entries"] as? List<*> ?: return null
                    if (entries.any { it !is String }) return null
                    SplitTunnelRules(enabled = enabled, entries = entries.map { it as String })
                }
            }
            val adBlock = if (root["adBlock"] == null) false else Json.boolean(root["adBlock"]) ?: return null
            return TunnelSetup(server = server, masking = masking, splitTunnel = bypass, adBlock = adBlock)
        }
    }
}
