package app.anemia.vpn

import android.net.VpnService
import android.os.SystemClock
import android.util.Log
import app.anemia.core.AdBlockDns
import app.anemia.core.AmneziaWg
import app.anemia.core.AntiCensorshipOptions
import app.anemia.core.emittableFragment
import app.anemia.core.emittableNoises
import app.anemia.core.Addresses
import app.anemia.core.AwgValidate
import app.anemia.core.BypassEntry
import app.anemia.core.ProxyServer
import app.anemia.core.Routes
import app.anemia.core.WgServer
import app.anemia.core.XrayConfigBuilder
import app.anemia.data.AppBypass
import app.anemia.data.TunnelSetup

/** Имя + сколько на него осталось: резолвер обязан уложиться в потолок. */
typealias Resolver = (name: String, timeoutMs: Long) -> List<String>

/** Тег процесса туннеля: в `logcat -s Anemia:V` должны быть видны обе половины. */
private const val TAG = "Anemia"

/**
 * Всё, что нужно для подъёма туннеля, посчитанное до `establish()`: какой
 * движок стартует с каким текстом конфига и какие адреса, маршруты и DNS
 * должна выставить система. Порт `iOS/AnemiaTunnel/TunnelPlan.swift`.
 *
 * Главное различие платформ: iOS принимает от приложения список *исключаемых*
 * маршрутов, а Android умеет только перечислять *включаемые* — поэтому обход
 * здесь вычитается (`Routes.included`), и в туннель уезжает дополнение до
 * обходимых сетей.
 */
object ConfigApplier {
    /** Xray буферизует по пакету на MTU; 1500 держит стек маленьким. */
    const val XRAY_MTU = 1500

    const val BYPASS_RESOLVER = "77.88.8.8"

    /** Столько же, сколько на iOS: четыре секунды на весь список обхода. */
    private const val LOOKUP_BUDGET_MS = 4_000L

    /** Попытки резолва эндпоинта: четыре окна по `PER_LOOKUP_BUDGET_MS`, как у iOS. */
    private const val ENDPOINT_LOOKUP_ATTEMPTS = 4
    private const val MAX_BYPASS_LOOKUPS = 40

    /** Один запрос не может съесть весь бюджет: `min(2 с, остаток)`, как на iOS. */
    private const val PER_LOOKUP_BUDGET_MS = 2_000L

    private const val XRAY_IPV4 = "172.19.0.1"
    private const val XRAY_IPV4_PREFIX = 30
    private const val XRAY_IPV6 = "fdfe:dcba:9876::1"
    private const val XRAY_IPV6_PREFIX = 126

    /** Заглушка IPv6: без неё полноценный туннель протекает IPv6 мимо VPN. */
    private const val IPV6_PLACEHOLDER = "fd00:a3e1:a::2"

    class Failure(message: String) : Exception(message)

    enum class Kind { Xray, AmneziaWG }

    data class Plan(
        val kind: Kind,
        /** JSON для xray либо `set=1` скрипт для AmneziaWG. */
        val argument: String,
        val addresses: List<AmneziaWg.TunAddress>,
        val routes: List<Pair<String, Int>>,
        val dns: List<String>,
        val mtu: Int,
    )

    /**
     * Порт `TunnelPlan.make(_:)`: что запустить и что для этого выставить в
     * системе. [resolver] обязан отвечать адресами *физической* сети и
     * вызываться до подъёма туннеля. Пустой ответ для имени — это потерянный
     * пункт обхода; туннель от этого не обязан падать.
     */
    fun plan(setup: TunnelSetup, logFile: String? = null, resolver: Resolver): Plan {
        val bypass = setup.splitTunnel?.activeEntries ?: emptyList()
        return if (setup.server.proto.isWireGuardFamily) {
            amneziaWG(setup.server, bypass, setup.adBlock, resolver)
        } else {
            xray(setup.server, setup, bypass, logFile, resolver)
        }
    }

    private fun endpointOf(server: ProxyServer, resolver: Resolver): String {
        val bare = server.address.trim('[', ']')
        if (Addresses.isIPv4(bare) || Addresses.isIPv6(bare)) return bare
        // Те же четыре окна по две секунды, что у iOS (`TunnelPlan.resolve`), а
        // не одна попытка на четыре: «черная дыра» в DNS съедает окно целиком,
        // а резолвер, ответивший со второй попытки, на Android значил «сервера
        // нет» там, где iOS подключался. Повторов ровно четыре, а не «до
        // дедлайна» — по той же причине, что и в Swift: отрицательный ответ
        // кешируется, и цикл по часам крутил бы `getAllByName` десятки тысяч
        // раз. Вранье про ANR из этого комментария тоже убрано: `plan()`
        // вызывают из `openTunnel`, а он стоит на рабочем потоке сервиса.
        repeat(ENDPOINT_LOOKUP_ATTEMPTS) {
            resolver(bare, PER_LOOKUP_BUDGET_MS).firstOrNull()?.let { return it }
        }
        throw Failure("Не удалось узнать адрес сервера ${server.address}")
    }

    private fun xray(
        original: ProxyServer,
        setup: TunnelSetup,
        bypass: List<BypassEntry>,
        logFile: String?,
        resolver: Resolver,
    ): Plan {
        val adBlock = setup.adBlock
        val endpoint = endpointOf(original, resolver)
        // Буфер 4 КБ, как в расширении, а не 512 по умолчанию: на iOS это
        // память под лимитом расширения, здесь — чтобы конфиг двух платформ
        // оставался одним текстом.
        val builder = XrayConfigBuilder(
            apiPort = null, logFile = logFile, mtu = XRAY_MTU, bufferSizeKB = 4,
        ).apply {
            this.bypass = bypass
            bypassResolver = BYPASS_RESOLVER
            collectsStats = true
            dnsQueryStrategy = "UseIPv4"
            if (adBlock) {
                remoteDNS = AdBlockDns.remoteDNS
                dnsHosts[AdBlockDns.dohHost] = AdBlockDns.servers[0]
                // AdGuard отвечает и с ближних узлов, так что локальные имена
                // продолжают резолвиться локально — и так же теряют рекламу.
                bypassResolver = AdBlockDns.servers[0]
            }
        }
        var dial = original
        if (endpoint != original.address) {
            if (original.proto.isHysteriaFamily) {
                // Её dial спросил бы систему, а система — уже туннель: звоним
                // на адрес, имя оставляем для TLS.
                if (original.sni.isNullOrEmpty()) {
                    dial = original.copy(address = endpoint, sni = original.address)
                } else {
                    dial = original.copy(address = endpoint)
                }
            } else {
                builder.dnsHosts[original.address] = endpoint
            }
        }
        // Движок читает `settings.noises`/`settings.fragment` строго, поэтому
        // эмиссия отбрасывает записи, которые он не загрузил бы (MaskingEmission.kt).
        // Молча отдать меньше маскирования, чем обещает название профиля, — тот
        // же самый тихий пропуск: это единственное место, где панельный брак
        // виден пользователю.
        val masking = setup.masking.options
        if (masking.fragment != null && masking.emittableFragment == null) {
            Log.w(TAG, "маскирование «${setup.masking.title}»: движок отверг фрагментацию — она не поедет")
        }
        val droppedNoises = masking.noises.size - masking.emittableNoises.size
        if (droppedNoises > 0) {
            Log.w(TAG, "маскирование «${setup.masking.title}»: движок отверг $droppedNoises " +
                "джунк-записей — они не поедут")
        }
        val config = try {
            builder.makeConfigString(dial, masking)
        } catch (error: Exception) {
            throw Failure(error.message ?: "Конфиг Xray не собрался")
        }
        // Маршруты считает сам движок (обход живёт в конфиге), поэтому системе
        // отдаётся ноль целиком — как на iOS, где у xray исключений нет.
        return Plan(
            kind = Kind.Xray,
            argument = config,
            addresses = listOf(
                AmneziaWg.TunAddress(XRAY_IPV4, XRAY_IPV4_PREFIX, ipv6 = false),
                AmneziaWg.TunAddress(XRAY_IPV6, XRAY_IPV6_PREFIX, ipv6 = true),
            ),
            routes = listOf("0.0.0.0" to 0, "::" to 0),
            dns = listOf("1.1.1.1"),
            mtu = XRAY_MTU,
        )
    }

    private fun amneziaWG(
        server: ProxyServer,
        bypass: List<BypassEntry>,
        adBlock: Boolean,
        resolver: Resolver,
    ): Plan {
        // Порядок как в `TunnelPlan.amneziaWG`: сначала замечания валидатора
        // (он же говорит и про отсутствующий профиль), и только потом профиль
        // нужен для маршрутов и DNS.
        AwgValidate.validate(server).firstOrNull()?.let { throw Failure("Конфиг AmneziaWG: $it") }
        val wg = WgServer.of(server) ?: throw Failure("Конфиг AmneziaWG без ключа сервера")
        val profile = requireNotNull(wg.profile)
        val endpoint = endpointOf(server, resolver)
        val uapi = try {
            AmneziaWg.uapiScript(server, endpoint)
        } catch (error: Exception) {
            throw Failure("Конфиг AmneziaWG: ${error.message}")
        }

        // Все адреса, которые профиль выдал этому peer, с их префиксами:
        // сервер принимает внутренние пакеты только с них.
        val assigned = AmneziaWg.tunnelInterfaceAddresses(server.userData?.get("wgAddress"))
        val addresses = ArrayList(assigned)
        if (assigned.none { !it.ipv6 }) {
            // Профиль без собственного IPv4: лучше выдуманный адрес, чем
            // неподнятый туннель (так же на iOS; лечится полным импортом).
            addresses += AmneziaWg.TunAddress(AmneziaWg.FALLBACK_TUN_ADDRESS, 32, ipv6 = false)
        }
        val allowed = profile.allowedIPs.mapNotNull { Routes.parse(it) }
        if (assigned.none { it.ipv6 } && allowed.any { it.ipv6 && it.bits == 0 }) {
            // Полноценный туннель без IPv6-адреса протекает IPv6 мимо VPN.
            addresses += AmneziaWg.TunAddress(IPV6_PLACEHOLDER, 128, ipv6 = true)
        }

        val routes = Routes.included(profile.allowedIPs, excludedNetworks(bypass, resolver))
            .map { it.substringBefore('/') to (it.substringAfter('/').toIntOrNull() ?: 0) }
        return Plan(
            kind = Kind.AmneziaWG,
            argument = uapi,
            addresses = addresses,
            routes = routes,
            dns = when {
                adBlock -> AdBlockDns.servers
                // `resolverAddresses`, а не `dns`: в строке `DNS =` у
                // wg-quick законны и имена (они уходят в `search`), а
                // `addDnsServer` ниже принимает только числовой адрес — одно
                // имя в списке обрывало подъём туннеля там, где macOS и iOS
                // подключаются. Правило общее для трёх платформ:
                // `WireGuardProfile.resolverAddresses`.
                profile.resolverAddresses.isNotEmpty() -> profile.resolverAddresses
                else -> listOf("1.1.1.1")
            },
            mtu = profile.mtu ?: 1280,
        )
    }

    /**
     * Сети обхода: литералы как есть, домены — теми адресами, что они имеют
     * сейчас. Бюджет [LOOKUP_BUDGET_MS] — тот же, что в iOS `excludedRoutes`:
     * у `InetAddress` нет своего таймера, одно чёрное-дыра имя стоит полминуты,
     * и всё это время сервис стоит в `onStartCommand`. Потерянный пункт обхода
     * отправит в туннель один сайт; не вернувшийся вовремя сервис не оставит
     * туннеля вовсе.
     */
    private fun excludedNetworks(
        bypass: List<BypassEntry>,
        resolver: Resolver,
    ): List<String> {
        val out = ArrayList<String>()
        val deadline = SystemClock.elapsedRealtime() + LOOKUP_BUDGET_MS
        var lookups = 0
        for (entry in bypass) {
            when (entry) {
                is BypassEntry.IPv4, is BypassEntry.IPv6 -> out.add(entry.value)
                is BypassEntry.Domain -> {
                    if (lookups >= MAX_BYPASS_LOOKUPS || !entry.value.contains('.')) continue
                    val left = deadline - SystemClock.elapsedRealtime()
                    if (left <= 0) continue
                    lookups += 1
                    val found = resolver(entry.value, minOf(PER_LOOKUP_BUDGET_MS, left))
                    out += found.filter { Addresses.isIPv4(it) }.map { "$it/32" }
                }
            }
        }
        return out
    }

    /**
     * Переносит план в `Builder`. [selfPackage] исключается обязательно:
     * сокеты самого движка не должны попадать в туннель, который они же и
     * поднимают. На iOS это делает система (трафик расширения в туннель не
     * идёт), на Android — `addDisallowedApplication` по UID приложения.
     */
    fun apply(builder: VpnService.Builder, plan: Plan, selfPackage: String): VpnService.Builder {
        builder.setSession("Anemia").setMtu(plan.mtu)
        for (address in plan.addresses) builder.addAddress(address.address, address.prefix)
        for ((network, prefix) in plan.routes) builder.addRoute(network, prefix)
        for (server in plan.dns) builder.addDnsServer(server)
        builder.addDisallowedApplication(selfPackage)
        // Обход по приложениям берётся из настроек, а не из `TunnelSetup`:
        // поле чужих пакетов существующим платформам нечего разбирать, а
        // список обязан дойти до `establish()` из процесса туннеля.
        for (pkg in AppBypass.selected()) {
            if (pkg == selfPackage) continue
            runCatching { builder.addDisallowedApplication(pkg) }.onFailure {
                // Молча потерять правило — значит пустить трафик выбранного
                // приложения в туннель; это тот случай, который надо видеть.
                Log.w(TAG, "обход по приложению $pkg не применён: ${it.message}")
            }
        }
        return builder
    }

    fun label(kind: Kind): String = when (kind) {
        Kind.Xray -> "Xray"
        Kind.AmneziaWG -> "AmneziaWG"
    }
}
