package app.anemia.data

import app.anemia.core.LearnedMasking
import app.anemia.core.PersistedState
import app.anemia.core.MaskingProfile
import app.anemia.core.ProxyServer
import app.anemia.core.ShareLinkParser
import app.anemia.core.SplitTunnelParser
import app.anemia.core.SplitTunnelRules
import app.anemia.core.StatePersistence
import app.anemia.core.StateCodec
import app.anemia.core.Subscription
import app.anemia.core.SubscriptionInfo
import app.anemia.core.SubscriptionParser
import app.anemia.core.SyncBundle
import app.anemia.core.parseErrorText
import app.anemia.core.splitOnNewlines
import app.anemia.core.trimFoundationSpaces
import app.anemia.core.trimSpaceLike
import java.util.UUID

/**
 * Список серверов и всё, что с ним делают: порт `importLink(_:)`, `servers`
 * и `persist()` из `Sources/LoaderApp/App/AppState.swift`, поверх
 * [StatePersistence].
 *
 * Файл тот же, что у macOS и iOS (`state.json`), поэтому между платформами
 * переносится один и тот же документ, а `Scripts/verify-state.sh` сверяет,
 * что записанное Kotlin'ом читает Swift-декодер.
 */
class ServerStore(
    private val persistence: StatePersistence,
    /** Куда ложатся заголовки панелей; `null` — только в память (прогоны `:core`). */
    private val panels: PanelStore? = null,
) {

    /**
     * Магазин живёт в процессе интерфейса, но обновлением подписок занимается
     * фоновый поток. Без этого замка два изменения `state` разбегаются: фоновый
     * поток читает состояние, пока главный удаляет сервер, и пишет обратно
     * уже устаревший список — вместе с файлом на диске.
     */
    private val monitor = Any()

    /**
     * Принять перенос с другого устройства — порт `importSync` (iOS) и
     * `importSync(_:applySettings:)` (macOS): добавляется то, чего ещё нет,
     * настройки переезжают только по явному согласию.
     *
     * Новые подписки здесь не загружаются: панель держит соединение до 30 с, и
     * шторка импорта не должна висеть на ней после того, как данные уже
     * сохранены. Кто зовёт [refresh] после этого — экран, ровно как на iOS.
     */
    fun applySync(bundle: SyncBundle, applySettings: Boolean): SyncBundle.Summary {
        val summary = synchronized(monitor) {
            val (summary, merged) = bundle.mergeInto(state, applySettings)
            state = merged
            persistLocked()
            summary
        }
        // Вне замка и по той же причине, что у `refreshStale`: экран перечитывает
        // список только по этому сигналу. Без него принятый перенос лежит в
        // `state.json`, а открытый экран показывает «Серверов пока нет», пока его
        // не пересоздать (замерено на устройстве: 2 сервера на диске, «0 серверов»
        // на экране).
        notifyChanges()
        return summary
    }

    /**
     * Подписки, приехавшие из бандла. Нормализация url — та же, что у
     * `SyncBundle.normalizedUrl`: сверять «уже есть» по сырой строке значило бы
     * завести вторую копию панели из-за лишнего слэша в конце.
     */
    fun subscriptionIdsFor(urls: Set<String>): List<UUID> = synchronized(monitor) {
        state.subscriptions
            .filter { SyncTransfer.normalized(it.url) in urls }
            .map { it.id }
    }

    /** Итог вставки «как прислали»: что добавилось, сколько строк пропущено и чем пахнет отказ. */
    data class Import(
        val added: List<ProxyServer>,
        val skipped: Int,
        val error: String?,
    ) {
        val ok: Boolean get() = added.isNotEmpty()
    }

    /** Что увидел автоматический раунд: сколько панелей счёл готовыми, сколько
     * загрузил и сколько без TLS отклонил гейт (на macOS это строка в журнале). */
    data class Round(val checked: Int, val loaded: Int, val skippedInsecure: Int) {
        val failed: Int get() = checked - loaded
    }

    var state: PersistedState = PersistedState()
        private set

    /** О последнем чтении файла: «не разобралось» показать обязательнее, чем молча начать с чистого. */
    var warning: String? = null
        private set

    val servers: List<ProxyServer> get() = state.allServers

    fun selected(): ProxyServer? = state.selectedServerID?.let { state.serverWithId(it) }

    fun reload(): PersistedState {
        val loaded = persistence.load()
        synchronized(monitor) {
            state = loaded.state
            // «Пусто» — не признак «ещё не читали»: второй reload в том же
            // процессе молча игнорировал бы диск, а кэш панелей — источник
            // интервала, по которому панель вообще допускаются до запроса.
            if (!panelsLoaded) {
                panelsLoaded = true
                panels?.load()?.let { panelInfo.putAll(it) }
            }
        }
        warning = when {
            !loaded.decoded -> "Файл состояния не разобрался — начали с пустого; копия рядом с ним"
            loaded.droppedEntries -> "Часть записей состояния не разобралась и пропала; копия рядом с файлом"
            else -> null
        }
        return state
    }

    /**
     * Вставка «как прислали»: одна ссылка, несколько строк, wg-quick конфиг
     * или тело подписки base64'ом. Развилка — дословно Swift: конфиг
     * определяется по `[Interface]`/`[Peer]` до деления на строки (он
     * многострочный по определению), одиночная ссылка идёт своим путём
     * (точный текст ошибки), всё остальное — разбором подписки, который
     * пропускает битые строки, а не роняет половину импорта.
     */
    fun importLink(raw: String): Import {
        val trimmed = trimSpaceLike(raw)
        val lines = splitOnNewlines(trimmed).map { trimFoundationSpaces(it) }.filter { it.isNotEmpty() }
        if (trimmed.contains("[Interface]") || trimmed.contains("[Peer]")) {
            return adding(trimmed) { ShareLinkParser.parseConfigText(it) }
        }
        if (lines.size == 1 && isShareLink(trimmed)) {
            return adding(trimmed) { ShareLinkParser.parse(it) }
        }
        val result = SubscriptionParser.parse(trimmed)
        if (result.servers.isEmpty()) {
            return Import(emptyList(), result.failures.size,
                result.failures.firstOrNull()?.second ?: "Нечего импортировать")
        }
        return add(result.servers, skipped = result.failures.size)
    }

    /**
     * Удалить сервер. Подписочные живут внутри своей подписки: убрать один из
     * них — значит переписать подписку, и ближайшее обновление вернёт его
     * обратно (ровно так же на macOS).
     */
    fun remove(id: UUID) {
        // Под `mutate`, а не «прочитал — изменил — записал»: фоновый поток
        // обновления держит снимок состояния, пока 30 с ждёт панель, и пишет
        // обратно целиком. Без замка здесь это молча возвращало удалённый
        // сервер в список и в файл.
        mutate {
            it.copy(
                servers = it.servers.filterNot { server -> server.id == id },
                subscriptions = it.subscriptions.map { sub ->
                    sub.copy(servers = sub.servers.filterNot { server -> server.id == id })
                },
                selectedServerID = it.selectedServerID?.takeIf { selected -> selected != id },
            )
        }
    }

    /**
     * Итог обновления подписки: что изменилось и, если не удалось, почему.
     * `kept` — список остался прежним (так и должно быть при отказе панели).
     */
    data class Refresh(val subscription: Subscription?, val info: SubscriptionInfo?, val error: String?)

    /** Панельные заголовки подписок: на macOS они живут в `UserDefaults`. */
    private val panelInfo = HashMap<UUID, SubscriptionInfo>()

    /** Один раз за жизнь процесса — см. `reload()`. */
    private var panelsLoaded = false

    /** Заголовки панели в памяти и на диске: между запусками их неоткуда взять,
     * пока панели не пора снова ничего просить. */
    private fun rememberPanel(id: UUID, info: SubscriptionInfo?) {
        if (info == null) return
        synchronized(monitor) {
            panelInfo[id] = info
            panels?.save(panelInfo)
        }
    }

    fun subscriptions(): List<Subscription> = synchronized(monitor) { state.subscriptions }

    /** Снимок, а не сам словарь: его читает композиция, а пишет поток загрузки. */
    fun infoOf(id: UUID): SubscriptionInfo? = synchronized(monitor) { panelInfo[id] }

    /**
     * Добавить подписку. Порядок как в Swift `addSubscription`: сначала
     * загрузка, и только успех её добавляет строку. Опечатка в URL или 403
     * иначе оставляли бы пустую запись, которая повторяет ошибку на каждом
     * раунде [refreshStale], а каждая попытка добавляла бы следующую пустую.
     */
    fun addSubscription(name: String, url: String): Refresh {
        val candidate = Subscription(name = name.ifEmpty { defaultName(url) }, url = url)
        val fetched = fetchInto(candidate)
        if (fetched is Fetched.Failed) return Refresh(null, fetched.info, fetched.error)
        val subscription = (fetched as Fetched.Ok).subscription
        return synchronized(monitor) {
            state = state.copy(
                subscriptions = state.subscriptions + subscription,
                selectedServerID = state.selectedServerID ?: subscription.servers.firstOrNull()?.id,
            )
            persistLocked()
            Refresh(subscription, panelInfo[subscription.id], null)
        }
    }

    /** Обновить подписку по её id; список не меняется, если загрузка не вышла. */
    fun refresh(id: UUID): Refresh {
        // Та же защита, что `refreshing.contains(id)` на iOS: автоматический
        // круг не поднимает `busy` на экране, и нажатое поверх него «обновить»
        // запускало вторую загрузку того же URL — два `carryingIDs` из разных
        // снимков, и последний молча переписывает список и выбор.
        val current = synchronized(monitor) {
            if (id in refreshing) return Refresh(null, null, ALREADY_LOADING)
            val found = state.subscriptions.firstOrNull { it.id == id }
            if (found != null) refreshing.add(id)
            found
        } ?: return Refresh(null, null, "Подписка не найдена")
        val fetched = try {
            fetchInto(current)
        } finally {
            synchronized(monitor) { refreshing.remove(id) }
        }
        if (fetched is Fetched.Failed) return Refresh(null, fetched.info, fetched.error)
        val subscription = (fetched as Fetched.Ok).subscription
        return synchronized(monitor) {
            state = state.copy(
                subscriptions = state.subscriptions.map { if (it.id == subscription.id) subscription else it },
            )
            reselectLocked()
            persistLocked()
            Refresh(subscription, panelInfo[subscription.id], null)
        }
    }

    /** Панели, чья загрузка идёт прямо сейчас (см. `refreshing` на iOS). */
    private val refreshing = mutableSetOf<UUID>()

    /** Один автоматический раунд за раз: панель держит соединение до 30 с. */
    private var refreshingStale = false

    /**
     * Когда панель уже трогали в этом процессе. Проверки таймера частые
     * (5 мин), а интервал панели — редкий: без этой отметки панель, у которой
     * загрузка стабильно падает (невалидный сертификат, мёртвый токен),
     * повторяла бы запрос каждые пять минут до бесконечности, потому что
     * `lastUpdated` у неё не двигается. На macOS и iOS тот же эффект даёт
     * редкий сам круг — 6 ч и полчаса.
     */
    private val lastAttempt = HashMap<UUID, Double>()

    /**
     * Автоматический раунд — порт `refreshStaleSubscriptions` (iOS) и
     * `refreshAllSubscriptions(allowInsecure: false)` (macOS). Решение «может ли
     * панель поменять список без пользователя» целиком в
     * [Subscription.refreshIsDue]: без TLS нельзя никогда, интервал берётся
     * тот, что попросила панель, и зажимается в `[1 ч, 24 ч]`. Флаг
     * `subscriptionAutoRefresh` — тот же, что в настройках macOS.
     *
     * `allowInsecure` отмечает раунд по нажатию человека: он обходит и гейт, и
     * интервал — ровно как тулбар на macOS.
     *
     * Возвращает счётчики, а не строку: окна журнала как на macOS здесь нет, и
     * текст пишет экран. `null` — круг не состоялся (идёт другой, нет
     * подписок, автообновление выключено): тогда правильно молчать и в логе.
     */
    fun refreshStale(allowInsecure: Boolean = false): Round? {
        val pending = synchronized(monitor) {
            if (refreshingStale || state.subscriptions.isEmpty() ||
                (!state.subscriptionAutoRefresh && !allowInsecure)) {
                null
            } else {
                refreshingStale = true
                val now = System.currentTimeMillis() / 1000.0
                val seen = state.subscriptions
                val ids = seen.map { it.id }.toSet()
                lastAttempt.keys.retainAll(ids)
                if (panelInfo.keys.retainAll(ids)) panels?.save(panelInfo)
                // Открыто ли время: тот же возраст и тот же backoff, но без
                // TLS-гейта — чтобы «пропущено гейтом» не смешивалось с
                // «панель ещё не созрела».
                fun ageAllows(subscription: Subscription): Boolean {
                    val interval = panelInfo[subscription.id]?.updateInterval
                    val attempted = lastAttempt[subscription.id]
                    if (!subscription.refreshIsDue(now, interval, allowInsecure = true)) return false
                    return attempted == null ||
                        now - attempted >= subscription.refreshMaxAge(interval)
                }
                val ready = seen.filter {
                    it.id !in refreshing && (allowInsecure || (it.tlsProtected && ageAllows(it)))
                }
                ready.forEach { lastAttempt[it.id] = now }
                // Сколько панелей отклонил именно гейт — та же строка, что
                // пишет macOS в свой журнал.
                val gated = seen.count { !it.tlsProtected && it.id !in refreshing && ageAllows(it) }
                ready to gated
            }
        } ?: return null
        val (due, gated) = pending
        var loaded = 0
        try {
            for (subscription in due) {
                if (refresh(subscription.id).subscription != null) loaded += 1
            }
        } finally {
            // Снять флаг обязан и этот путь, и тот, где готовых ноль: иначе
            // флаг остаётся навсегда, и автообновление кончается молча.
            synchronized(monitor) { refreshingStale = false }
            // И экран перерисовать: если круг оборвался на середине, часть
            // списков уже переписана, а `revision` поднимает только этот сигнал.
            notifyChanges()
        }
        return Round(checked = due.size, loaded = loaded, skippedInsecure = gated)
    }

    /**
     * Подписка на изменения: раунд живёт в фоновом потоке и свой `revision`
     * экрану не поднимет. Слушатель вызывается тем потоком, что менял
     * состояние, — в Compose это переправляют на главный.
     */
    fun observeChanges(onChange: () -> Unit): () -> Unit {
        synchronized(monitor) { listeners.add(onChange) }
        return { synchronized(monitor) { listeners.remove(onChange) } }
    }

    private fun notifyChanges() {
        for (listener in synchronized(monitor) { listeners.toList() }) {
            runCatching { listener() }.onFailure {
                // Без этой строки сломанный слушатель выглядел бы как «экран
                // сам не перерисовался».
                android.util.Log.w("anemia", "change listener failed: ${it.message}")
            }
        }
    }

    private val listeners = mutableListOf<() -> Unit>()

    /**
     * Сеть вне замка и вне состояния: панель может держать соединение до 30 с,
     * и всё это время пользователь добавляет серверы руками.
     *
     * Причина отказа возвращается вместе с результатом, а не кладётся в общее
     * поле: две параллельные загрузки (круг + нажатое «обновить») показывали бы
     * ошибку чужой панели.
     */
    private sealed interface Fetched {
        data class Ok(val subscription: Subscription) : Fetched
        data class Failed(val error: String, val info: SubscriptionInfo? = null) : Fetched
    }

    private fun fetchInto(subscription: Subscription): Fetched {
        val response = try {
            SubscriptionFetcher.fetch(subscription.url)
        } catch (error: SubscriptionFetcher.FetchError) {
            return Fetched.Failed(error.message ?: "Fetch failed")
        } catch (error: Exception) {
            return Fetched.Failed("Fetch failed: ${error.message ?: error.javaClass.simpleName}")
        }
        if (response.status !in 200..299) {
            return Fetched.Failed("Fetch failed: HTTP ${response.status}")
        }
        val panel = SubscriptionInfo.parse(response.headers)
        val parsed = SubscriptionParser.parse(response.body)
        if (parsed.servers.isEmpty()) {
            // Пустой или мусорный ответ — отказ загрузки, а не «серверов больше
            // нет»: сохранение пустого результата стирало список при каждом
            // сбое провайдера.
            val expired = panel?.expires?.let { it < System.currentTimeMillis() / 1000 } == true
            if (expired) rememberPanel(subscription.id, panel)
            return Fetched.Failed(
                if (expired) "The subscription expired"
                else parsed.failures.firstOrNull()?.let { "Subscription has no usable servers (${it.second})" }
                    ?: "Subscription has no usable servers",
                panel,
            )
        }
        rememberPanel(subscription.id, panel)
        return Fetched.Ok(subscription.copy(
            // Перенос id между обновлениями: на них держатся история проб и
            // выученное маскирование, а выбор сервера не должен уезжать.
            servers = SubscriptionParser.carryingIDs(subscription.servers, parsed.servers),
            // Секунды от опорной даты Foundation — тот же формат, что в `state.json`.
            lastUpdated = System.currentTimeMillis() / 1000.0 - Subscription.REFERENCE_DATE_SECONDS,
        ))
    }

    /**
     * Правило Swift: если выбранного сервера в списке больше нет (панель
     * переименовала ссылку), выбор переезжает на первый доступный, а не висит
     * id, которого не существует.
     */
    private fun reselectLocked() {
        val selected = state.selectedServerID ?: return
        if (state.serverWithId(selected) != null) return
        state = state.copy(selectedServerID = state.allServers.firstOrNull()?.id)
    }

    fun removeSubscription(id: UUID) {
        // Удаление записывается сразу: иначе после перезапуска строка
        // вернётся вместе с кэшированными заголовками панели.
        synchronized(monitor) {
            panelInfo.remove(id)
            panels?.save(panelInfo)
        }
        mutate { it.copy(subscriptions = it.subscriptions.filterNot { sub -> sub.id == id }) }
        // Выбор сбрасывается, только если сервера вообще больше нет: сервер,
        // добавленный вручную, от удаления подписки не исчезает. Молча
        // переставлять выбор под живым соединением нельзя. На macOS это
        // отдельное правило: там приложение знает `sessionServerID` и рвёт
        // сессию, если удалила именно её сервер. Здесь туннель держит свой
        // экземпляр `TunnelSetup` в процессе `:vpn` и живёт до «Отключить», а
        // какое соединение живёт — экран пока не знает (нет канала статуса,
        // как в `TunnelReport` на iOS), так что это остаётся на пользователе.
        mutate { current ->
            val selected = current.selectedServerID
            if (selected != null && current.serverWithId(selected) == null) {
                current.copy(selectedServerID = null)
            } else current
        }
    }

    /** Имя по умолчанию — хост без порта, как `URL(string:)?.host` на iOS. */
    private fun defaultName(url: String): String {
        val authority = url.substringAfter("://", url).substringBefore('/').substringBefore('?')
        // IPv6 пишется в скобках, и у него двоеточие внутри адреса.
        if (authority.startsWith("[")) return authority.substringBefore(']', authority)
        return authority.substringBeforeLast(':', authority)
    }

    fun select(id: UUID) {
        mutate { if (it.serverWithId(id) == null) it else it.copy(selectedServerID = id) }
    }

    /** Насколько агрессивно маскироваться — то же поле состояния, что у macOS. */
    fun setMasking(profile: MaskingProfile) {
        mutate { it.copy(maskingProfile = profile) }
    }

    fun setSubscriptionAutoRefresh(enabled: Boolean) {
        mutate { it.copy(subscriptionAutoRefresh = enabled) }
    }

    /**
     * С каким маскированием подключать сервер: выученный для него профиль
     * (`LearnedMasking`, тот же в состоянии, что на macOS/iOS и приезжающий в
     * бандле переноса), а иначе выбранный пользователем. Правило то же, что
     * `masking(for:)` на iOS: выученное важнее глобального, но только когда он
     * отличается.
     */
    fun maskingFor(server: ProxyServer): MaskingProfile =
        LearnedMasking.profileFor(state, server, network = null) ?: state.maskingProfile

    /** Запомнить профиль, который действительно провёл этот сервер. */
    fun learnedMasking(profile: MaskingProfile, server: ProxyServer) {
        mutate { LearnedMasking.learned(it, profile, server, network = null) }
    }

    /** Правила «Мимо VPN»: текст полей живёт в состоянии, а не в настройках приложения. */
    /**
     * Сохранить обход. Форма — как у Swift-редактора: нормализованные принятые
     * записи плюс строки, которые разбор отверг, чтобы ни один набранный адрес
     * не потерялся при следующем открытии.
     */
    fun setBypass(text: String, enabled: Boolean? = null) = mutate {
        val parsed = SplitTunnelParser.parse(text)
        it.copy(
            splitTunnel = it.splitTunnel.copy(
                enabled = enabled ?: it.splitTunnel.enabled,
                entries = parsed.entries.map { entry -> entry.value } + parsed.rejected.map { it.line },
            ),
        )
    }

    fun setBypassEnabled(enabled: Boolean) {
        mutate { it.copy(splitTunnel = it.splitTunnel.copy(enabled = enabled)) }
    }

    private fun adding(text: String, parse: (String) -> ProxyServer): Import = try {
        add(listOf(parse(text)))
    } catch (error: Exception) {
        Import(emptyList(), 0, parseErrorText(error))
    }

    private fun add(parsed: List<ProxyServer>, skipped: Int = 0): Import {
        mutate {
            it.copy(
                servers = it.servers + parsed,
                selectedServerID = it.selectedServerID ?: parsed.first().id,
            )
        }
        return Import(parsed, skipped, null)
    }

    /** Правка состояния и запись файла — под одним замком. */
    private fun mutate(block: (PersistedState) -> PersistedState) = synchronized(monitor) {
        state = block(state)
        persistLocked()
    }

    private fun persist() = synchronized(monitor) { persistLocked() }

    private fun persistLocked() {
        runCatching { persistence.save(state) }
            .onFailure { warning = "Состояние не сохранилось: ${it.message}" }
    }

    /** Те же схемы, что у Swift: `isShareLink(_:)`. */
    private fun isShareLink(line: String): Boolean {
        val l = line.lowercase()
        return listOf(
            "vless://", "vmess://", "ss://", "trojan://", "amnezia://", "awg://",
            "wireguard://", "wg://", "hysteria://", "hysteria2://", "hy2://", "vpn://",
        ).any { l.startsWith(it) }
    }

    private companion object {
        /** Та же формулировка отказа, что у крутящейся панели на iOS. */
        const val ALREADY_LOADING = "Уже обновляется"
    }
}
