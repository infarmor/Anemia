import LoaderCore
import SwiftUI

struct DiagnosticsView: View {
    @Environment(TunnelController.self) private var tunnel

    var body: some View {
        List {
            Section {
                if let report = tunnel.report {
                    LabeledContent("Движки") {
                        Text(report.engineVersion)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Память расширения", value: memoryLine(report))
                } else {
                    Text("Сведения о движке видны, пока туннель запущен.")
                        .foregroundStyle(Theme.inkSoft)
                }
                NavigationLink {
                    EngineLogView()
                } label: {
                    Label("Лог движка", systemImage: "doc.text")
                }
            } header: {
                Text("Движок")
            } footer: {
                Text("Расширение VPN iOS завершает, если оно занимает больше ~50 МБ.")
            }
            .listRowBackground(Theme.card)

            Section {
                AwgSection()
            } header: {
                Text("AmneziaWG")
            } footer: {
                Text("То, что делает конфиг «рабочим», но не пропускает трафик: размер junk-пакета не ниже MTU, перекрывающиеся диапазоны H1–H4, S1 + 56 = S2. Сообщения совпадают с тем, что пишет macOS-приложение и Android-порт.")
            }
            .listRowBackground(Theme.card)

            Section {
                RoutingSection()
            } header: {
                Text("Маршрутизация")
            } footer: {
                Text("Флаги прочитаны из конфигурации, которую хранит iOS, а не из настроек приложения: «маршруты выше таблицы» — это то, что система умеет молча не учитывать (при включённом kill switch — точно не учитывает). Проверить раздачу: включите точку доступа, скачайте что-нибудь на подключённом устройстве и смотрите на счётчики трафика — с работающей раздачей через туннель они растут. Цвет там, где сохранённое расходится с настройками: переподключите VPN.")
            }
            .listRowBackground(Theme.card)

            Section {
                LiveActivitySection()
            } header: {
                Text("Live Activity")
            } footer: {
                Text("ActivityKit молча бросает обновления и завершает активность, когда её нельзя запустить из фона. «Контент» старше «Отправлено» — значит система перестала принимать обновления; «молчит» в фоновом аудио — приложение усыплено, и остров остаётся с последними цифрами.")
            }
            .listRowBackground(Theme.card)

            Section {
                SigningSection()
            } header: {
                Text("Подпись")
            } footer: {
                Text("«Нет» — приложение не подписано (симулятор или сборка до GBox).")
            }
            .listRowBackground(Theme.card)
        }
        .anemiaList()
        .navigationTitle("Диагностика")
    }

    /// `os_proc_available_memory()` answers "no limit" for a process iOS
    /// doesn't cap, and the tunnel reports 0 for it rather than a wrapped -1.
    /// Printing that as a budget would read as "the extension already ate it
    /// all"; UInt64.max, which the same value used to travel as, printed the
    /// ceiling as ~9,2 ЭБ next to a footer about 50 МБ.
    private func memoryLine(_ report: TunnelReport) -> String {
        let footprint = size(report.footprint)
        guard report.available > 0, report.available < UInt64.max / 2 else {
            return "\(footprint), лимита нет"
        }
        return "\(footprint) из ~\(size(report.footprint.addingReportingOverflow(report.available).partialValue))"
    }

    /// `Int64()` traps on anything above Int64.max, and a saturating add can
    /// hand it exactly that.
    private func size(_ bytes: UInt64) -> String {
        Int64(clamping: bytes).formatted(.byteCount(style: .memory))
    }
}

/// The routing flags as iOS keeps them, next to what the app asked for:
/// `enforceRoutes` is the one the system quietly drops — `includeAllNetworks`
/// overrides it by design — and a hotspot that doesn't go through the tunnel
/// is otherwise invisible from inside the app.
private struct RoutingSection: View {
    @Environment(TunnelController.self) private var tunnel
    @Environment(ServerStore.self) private var store

    var body: some View {
        if let saved = tunnel.savedRouting {
            row("Kill switch — весь трафик в туннель", wanted: store.killSwitch, saved: saved.killSwitch)
            row("Маршруты выше таблицы iOS — раздача", wanted: store.hotspotThroughVPN, saved: saved.enforcedRoutes)
            row("Локальная сеть мимо туннеля", wanted: true, saved: saved.localNetworksExcluded)
        } else {
            Text("Конфигурации туннеля ещё нет — подключитесь хотя бы раз.")
                .foregroundStyle(Theme.inkSoft)
        }
    }

    private func row(_ title: String, wanted: Bool, saved: Bool) -> some View {
        LabeledContent(title) {
            Text(saved ? "включено" : "выключено")
                .foregroundStyle(saved == wanted ? Theme.ink : Theme.accent)
        }
    }
}

/// What the AmneziaWG validator says about the server in use (or the chosen
/// one, while the tunnel is down). macOS logs the same list at connect; on iOS
/// it was computed nowhere, so a config that handshakes and then drops every
/// packet had nothing to explain itself with.
private struct AwgSection: View {
    @Environment(TunnelController.self) private var tunnel
    @Environment(ServerStore.self) private var store

    private var server: ProxyServer? {
        // `activeServerID` — это «с кем конфигурация последний раз сохранена»,
        // и при остановке она не сбрасывается: без проверки `isOn` диагностика
        // продолжала показывать поколения, MTU и ошибки уже выключенного выхода,
        // а список серверов тем временем отмечал другой выбранный — ровно то,
        // что обещает не делать соседний комментарий выше.
        let id = (tunnel.isOn ? tunnel.activeServerID : nil) ?? store.selected?.id
        let found = id.flatMap { store.state.server(withID: $0) }
        return found?.proto.isWireGuardFamily == true ? found : nil
    }

    var body: some View {
        if let server {
            let problems = AmneziaWGConfigBuilder.validate(
                server: server, mtu: server.wgProfile?.mtu ?? 1420) +
                AmneziaWGConfigBuilder.warnings(server: server).map { "⚠ " + $0 }
            LabeledContent("Сервер", value: server.name)
            LabeledContent("Поколение", value: "AmneziaWG \(server.awgVersion.rawValue)")
            LabeledContent("MTU", value: server.wgProfile?.mtu.map(String.init) ?? "1420")
            if problems.isEmpty {
                Label("Замечаний нет", systemImage: "checkmark.seal")
                    .foregroundStyle(Theme.ink)
            }
            ForEach(problems, id: \.self) { problem in
                Label(problem, systemImage: problem.hasPrefix("⚠")
                      ? "exclamationmark.triangle" : "xmark.seal")
                    .font(.footnote)
                    .foregroundStyle(problem.hasPrefix("⚠") ? Theme.inkSoft : Theme.accent)
            }
        } else {
            Text("Сервер AmneziaWG или WireGuard не выбран.")
                .foregroundStyle(Theme.inkSoft)
        }
    }
}

/// What the Live Activity and the thing that feeds it are doing right now.
/// The numbers move, so the block redraws itself twice a second.
private struct LiveActivitySection: View {
    @Environment(LiveActivityController.self) private var liveActivity

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let d = liveActivity.diagnostics
            if !d.systemAllows {
                Text("Live Activity для Anemia выключены в Настройках iOS: Anemia → Live Activity.")
                    .foregroundStyle(Theme.accent)
            } else if !d.enabled {
                Text("Live Activity выключены в настройках Anemia.")
                    .foregroundStyle(Theme.inkSoft)
            }
            LabeledContent("Активность") {
                Text(d.activity?.presentation.rawValue ?? "не запущена")
                    .foregroundStyle(health(d))
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Состояние туннеля", value: d.phase.map(Self.phaseText) ?? "сессии нет")
            if let activity = d.activity {
                LabeledContent("Остров показывает", value: Self.phaseText(activity.shown))
                LabeledContent("Устареет", value: relative(activity.staleAt))
            }
            if let shown = d.phase, let activity = d.activity, activity.shown != shown, d.feedRunning {
                // The system never says it dropped an update; this is how it
                // shows: what we sent and what the island still holds differ.
                Text("Отправили «\(Self.phaseText(shown))», остров держит «\(Self.phaseText(activity.shown))» — обновления не проходят.")
                    .foregroundStyle(Theme.accent)
            }
            LabeledContent("Фид", value: d.feedRunning
                           ? "каждые \(Int(LiveActivityController.feedInterval)) с"
                           : "остановлен")
            if d.startBlocked {
                // Единственная причина пустого острова, у которой нет ошибки
                // ActivityKit: отказ или свайп блокируют старт до переднего
                // плана.
                Text("Новую активность просим заново при выходе на экран (или «Обновить сейчас»).")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }
            LabeledContent("Обновлений в минуту", value: "\(d.updatesPerMinute)")
            LabeledContent("Отправлено", value: relative(d.lastSend))
            LabeledContent("Фоновое аудио") {
                Text(d.keeperRunning
                     ? (d.keeperProducing ? "играет" : "молчит, рестартов: \(d.keeperRestarts)")
                     : "выключено")
                    .foregroundStyle(d.keeperRunning && !d.keeperProducing ? Theme.accent : Theme.inkSoft)
                    .multilineTextAlignment(.trailing)
            }
            // Когда iOS в последний раз вернула себе поток — половина ответа на
            // «почему остров замёрз в 14:20»; счётчик рестартов ниже сам по себе
            // не говорит, было это минуту назад или в начале сессии.
            if let at = d.keeperLastRestart {
                Text("аудио поднимали в \(at.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "ru_RU"))))")
                    .font(.caption)
                    .foregroundStyle(Theme.inkSoft)
            }
            if let error = d.lastError {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ActivityKit отказала")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    Text(error)
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.inkSoft)
                        .textSelection(.enabled)
                    if let at = d.lastErrorAt {
                        Text(at.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "ru_RU"))))
                            .font(.caption2)
                            .foregroundStyle(Theme.inkSoft)
                    }
                }
            }
            // `backInFront()`, а не `sync()`: полоса «просим старт только с
            // переднего плана» снимается здесь, иначе кнопка не помогла бы
            // приложению, которое и так на экране.
            Button("Обновить сейчас") { liveActivity.backInFront() }
        }
    }

    /// The accent colour when the island should be showing something and
    /// isn't: stale, ended, or swiped away while the feed keeps running.
    private func health(_ d: LiveActivityController.Diagnostics) -> Color {
        guard let activity = d.activity else { return Theme.inkSoft }
        return activity.presentation == .active ? Theme.ink : Theme.accent
    }

    /// "5 с назад", "через 40 с" — the same form for past and future.
    private func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(.relative(presentation: .named).locale(Locale(identifier: "ru_RU")))
    }

    private static func phaseText(_ phase: TunnelActivityAttributes.ContentState.Phase) -> String {
        switch phase {
        case .connecting: "подключение"
        case .connected: "подключено"
        case .reconnecting: "обрыв"
        case .searching: "поиск сервера"
        case .ended: "итог"
        }
    }
}

private struct EngineLogView: View {
    @Environment(TunnelController.self) private var tunnel
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text)
                .font(.caption2.monospaced())
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .background(Theme.ground)
        .navigationTitle("Лог движка")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: text)
                    .disabled(text.isEmpty)
            }
        }
        .refreshable { text = await tunnel.fetchLog() }
        .task { text = await tunnel.fetchLog() }
    }
}

private struct SigningSection: View {
    private let tunnelBundle = AppBundle.tunnelExtension

    var body: some View {
        LabeledContent("Приложение", value: Bundle.main.bundleIdentifier ?? "—")
        LabeledContent("Расширение", value: tunnelBundle?.bundleIdentifier ?? "не найдено")
        // Права на VPN видны в строках ниже, а вот «есть ли общая папка, через
        // которую виджет читает состояние» — нет нигде. Без GBox в ipa нет
        // `embedded.mobileprovision`, группу найти нечем, и виджет показывает
        // «Сервер не выбран» при работающем туннеле — со стороны это выглядит
        // как испорченный виджет, а не как отсутствующая группа.
        LabeledContent("Общая папка", value: SharedStore.isAvailable
                       ? (SharedStore.container?.lastPathComponent ?? "есть")
                       : "не найдена — виджет читает только своё")
        ProfileRow(title: "Профиль приложения", profile: ProvisioningProfile(bundleURL: Bundle.main.bundleURL))
        ProfileRow(
            title: "Профиль расширения",
            profile: tunnelBundle.flatMap { ProvisioningProfile(bundleURL: $0.bundleURL) }
        )
    }
}

private struct ProfileRow: View {
    let title: String
    let profile: ProvisioningProfile?

    var body: some View {
        if let profile {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: profile.allowsPacketTunnel ? "checkmark.seal" : "xmark.seal")
                    .foregroundStyle(profile.allowsPacketTunnel ? Theme.ink : Theme.accent)
                Group {
                    Text(profile.appID)
                    if let expires = profile.expires {
                        Text("действует до \(expires.formatted(Date.FormatStyle(date: .long, time: .omitted).locale(Locale(identifier: "ru_RU")))))")
                    }
                    Text(profile.allowsPacketTunnel ? "право packet-tunnel-provider есть" : "права packet-tunnel-provider нет")
                }
                .font(.footnote)
                .foregroundStyle(Theme.inkSoft)
            }
        } else {
            LabeledContent(title, value: "нет")
        }
    }
}
