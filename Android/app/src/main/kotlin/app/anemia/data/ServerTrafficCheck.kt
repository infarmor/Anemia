package app.anemia.data

import app.anemia.core.MaskingProfile
import app.anemia.core.ProxyServer
import app.anemia.core.XrayConfigBuilder
import app.anemia.vpn.Engine
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/** Tests that an Xray profile actually carries HTTPS without changing the VPN's selection. */
internal object ServerTrafficCheck {
    data class Verdict(val label: String, val latency: Long? = null)

    fun supports(server: ProxyServer): Boolean =
        !server.proto.isWireGuardFamily && !server.proto.isHysteriaFamily

    suspend fun check(
        servers: List<ProxyServer>,
        initial: MaskingProfile,
        onResult: (ProxyServer, Verdict) -> Unit,
    ) {
        for (batch in servers.filter(::supports).chunked(2)) {
            val verdicts = withContext(Dispatchers.IO) { runBatch(batch, initial) }
            for ((server, verdict) in verdicts) onResult(server, verdict)
        }
    }

    private fun runBatch(servers: List<ProxyServer>, profile: MaskingProfile): List<Pair<ProxyServer, Verdict>> {
        val attempt = probe(servers, profile)
        val retryProfile = profile.escalated
        val failed = servers.filter { attempt[it.id.toString()] == 0L }
        val retried = if (retryProfile != null && failed.isNotEmpty()) probe(failed, retryProfile) else emptyMap()

        return servers.map { server ->
            val id = server.id.toString()
            val retry = retried[id]
            val first = attempt[id]
            server to when {
                first == -1L -> Verdict("Профиль не поддерживается")
                first != null && first > 0L -> Verdict("Трафик проходит", first)
                retry != null && retry > 0L -> Verdict("Работает с маскированием " + retryProfile?.title, retry)
                first == null -> Verdict("Проверка недоступна")
                else -> Verdict("Трафик не проходит")
            }
        }
    }

    private fun probe(servers: List<ProxyServer>, profile: MaskingProfile): Map<String, Long> {
        val results = mutableMapOf<String, Long>()
        val requests = JSONArray()
        val builder = XrayConfigBuilder(enableSniffing = false, hijackDNS = false, blockQUIC = false)
        for (server in servers) {
            val id = server.id.toString()
            val config = try {
                JSONObject(builder.makeConfigString(server, profile.options)).apply { remove("inbounds") }
            } catch (_: Exception) {
                results[id] = -1
                continue
            }
            requests.put(JSONObject().put("id", id).put("config", config.toString()))
        }
        if (requests.length() == 0) return results
        val answer = Engine.probe(requests.toString()) ?: return results
        val rows = runCatching { JSONArray(answer) }.getOrNull() ?: return results
        for (index in 0 until rows.length()) {
            val row = rows.optJSONObject(index) ?: continue
            results[row.optString("id")] = row.optLong("ms").coerceAtLeast(0L)
        }
        return results
    }
}
