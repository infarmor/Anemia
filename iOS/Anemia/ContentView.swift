import LoaderCore
import NetworkExtension
import SwiftUI

/// The main screen, laid out like the Mac app's window: the world map as the
/// hero with the connection state written onto it, the server you exit
/// through, live traffic, and the protection posture as grouped rows. The VPN
/// switch lives in the navigation bar.
struct ContentView: View {
    @Environment(TunnelController.self) private var tunnel
    @Environment(ServerStore.self) private var store
    @Environment(LiveActivityController.self) private var liveActivity
    @Environment(PingController.self) private var pings
    @Environment(QuickActions.self) private var actions
    @Environment(TrafficStats.self) private var stats
    @Environment(SpeedTest.self) private var speedTest
    @Environment(NetworkWatcher.self) private var network
    @Environment(LeakChecker.self) private var leaks
    @Environment(AppRouter.self) private var router
    @Environment(\.openURL) private var openURL

    @State private var showingServers = false
    @State private var showingSettings = false
    @State private var showingScanner = false
    @State private var showingLeakCheck = false
    @State private var importRequest: ImportRequest?
    @State private var incoming: IncomingBundle?
    @State private var transferError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    hero
                    VStack(spacing: 16) {
                        notices
                        if store.allServers.isEmpty {
                            welcome
                        }
                        serverBar
                        if tunnel.isOn {
                            traffic
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        protectionGroup
                        connectionGroup
                        statsGroup
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                    .animation(Theme.spring, value: tunnel.isOn)
                }
            }
            .background(Theme.ground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .navigationDestination(isPresented: $showingLeakCheck) {
                LeakCheckView()
            }
            .sheet(isPresented: $showingScanner) {
                QRScannerSheet { payload in Task { await receive(payload) } }
            }
            .task(id: router.leakCheckRequested) {
                // From the app icon's menu.
                guard router.leakCheckRequested else { return }
                router.leakCheckRequested = false
                showingLeakCheck = true
            }
            .sensoryFeedback(trigger: tunnel.status) { old, new in
                switch new {
                case .connected: .success
                case .disconnected where old == .connected || old == .disconnecting: .impact(weight: .light)
                default: nil
                }
            }
            .sensoryFeedback(.selection, trigger: store.selected?.id)
            .sheet(isPresented: $showingServers) {
                ServersView()
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(item: $importRequest) { request in
                ImportSheet(prefill: request.text)
            }
            .sheet(item: $incoming) { incoming in
                SyncImportSheet(bundle: incoming.bundle)
            }
            .onOpenURL { url in
                // An .anemia file from AirDrop or Files, a sync link, or
                // something to import.
                if url.isFileURL {
                    // Файл читается и декодируется вне главного актёра
                    // (`IncomingBundle.load`): выгруженный в iCloud бандл
                    // встал бы здесь на всё приложение.
                    Task {
                        do { incoming = try await IncomingBundle.load(fileURL: url) }
                        catch { transferError = error.localizedDescription }
                    }
                    return
                }
                let link = url.absoluteString
                Task {
                    do {
                        if let bundle = try await IncomingBundle.load(text: link) {
                            incoming = bundle
                        } else if let text = DeepLink.importText(from: url) {
                            importRequest = ImportRequest(text: text)
                        }
                    } catch {
                        transferError = error.localizedDescription
                    }
                }
            }
            .alert("Перенос не удался", isPresented: Binding(get: { transferError != nil },
                                                             set: { if !$0 { transferError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(transferError ?? "")
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // Centred: in a leading glass capsule iOS squeezes the mark to a dot.
        ToolbarItem(placement: .principal) {
            BrandMark()
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("Настройки", systemImage: "gearshape") { showingSettings = true }
                .labelStyle(.iconOnly)
        }
        ToolbarItem(placement: .topBarTrailing) {
            // A real switch: in a toolbar iOS 26 otherwise draws a toggle as
            // a text button.
            Toggle("VPN", isOn: vpnSwitch)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(tunnel.isBusy)
        }
    }

    private var vpnSwitch: Binding<Bool> {
        Binding(
            get: { tunnel.isOn },
            set: { on in
                guard on else {
                    Task { await actions.disconnect() }
                    return
                }
                guard store.selected != nil else {
                    showingServers = true
                    return
                }
                Task { await actions.connectSelected(waitUntilConnected: false) }
            }
        )
    }

    // MARK: - Hero

    /// The map carries the session; the state is written straight onto it and
    /// its edges fade into the screen, so nothing boxes in the most important
    /// thing here.
    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            WorldMap(snapshot: mapSnapshot, canPick: !tunnel.isOn) { code in
                pickCountry(code)
            }
            .frame(height: 232)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    statusGlyph
                    Text(statusTitle)
                        .font(.system(size: 30, weight: .medium, design: .serif))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .contentTransition(.opacity)
                }
                statusDetail
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
        .animation(Theme.spring, value: statusTitle)
    }

    @ViewBuilder private var statusGlyph: some View {
        if tunnel.status == .connecting {
            ProgressView()
                .frame(width: 28, height: 28)
        } else {
            Image(systemName: statusSymbol)
                .font(.system(size: 23, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tunnel.isOn ? statusColor : Theme.inkSoft)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 28)
        }
    }

    @ViewBuilder private var statusDetail: some View {
        if tunnel.status == .connected, let report = tunnel.report {
            HStack(spacing: 5) {
                SessionClock(start: report.startedAt)
                if let latency = report.latency {
                    Text("·")
                    Text("\(latency) мс")
                }
                if let speed = tunnel.speed {
                    Text("·")
                    Text(Speed.text(speed.download))
                        .contentTransition(.numericText())
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.inkSoft)
            .lineLimit(1)
        } else {
            Text(hint)
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkSoft)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusTitle: String {
        switch tunnel.status {
        case .connected: "Защищено"
        case .connecting: "Подключение…"
        case .reasserting: "Переподключение…"
        case .disconnecting: "Отключение…"
        default: store.selected == nil ? "Нет сервера" : "Не подключено"
        }
    }

    private var statusSymbol: String {
        switch tunnel.status {
        case .connected: "checkmark.shield.fill"
        case .connecting, .reasserting: "arrow.triangle.2.circlepath"
        case .disconnecting: "shield.lefthalf.filled"
        default: tunnel.lastError == nil ? "shield.slash" : "exclamationmark.shield"
        }
    }

    private var statusColor: Color {
        tunnel.status == .connected || tunnel.status == .connecting ? Theme.accent : Theme.ink
    }

    private var hint: String {
        if tunnel.status == .reasserting { return "Связь прервалась — восстанавливаю" }
        if actions.isSwitching { return "Проверяю серверы…" }
        guard let server = store.selected else {
            return "Добавьте сервер: ссылку, подписку или QR-код"
        }
        // While the tunnel runs, name the server actually carrying traffic —
        // the map and the widget read the same source, and a switch that the
        // engine refused must not make this line claim an exit in use.
        let active = tunnel.isOn
            ? tunnel.activeServerID.flatMap { store.state.server(withID: $0) } ?? server
            : server
        if tunnel.isOn { return "Через «\(active.name)»" }
        return "Включите VPN переключателем вверху"
    }

    private var mapSnapshot: WorldMap.Snapshot {
        var parks: [String: (count: Int, best: Int?)] = [:]
        for server in store.allServers {
            guard let code = Country.code(inServerName: server.name), CountryGeo.centers[code] != nil else { continue }
            var park = parks[code] ?? (0, nil)
            park.count += 1
            if case .ms(let ms) = pings.results[server.id] {
                park.best = min(park.best ?? .max, ms)
            }
            parks[code] = park
        }
        var snapshot = WorldMap.Snapshot()
        snapshot.parks = parks.keys.sorted().map {
            WorldMap.Park(code: $0, count: parks[$0]?.count ?? 1, best: parks[$0]?.best)
        }
        if let region = Locale.current.region?.identifier.uppercased(), CountryGeo.centers[region] != nil {
            snapshot.home = region
        }
        let live = tunnel.isOn ? tunnel.activeServerID.flatMap { store.state.server(withID: $0) } : nil
        if let server = live ?? store.selected,
           let code = Country.code(inServerName: server.name), CountryGeo.centers[code] != nil {
            snapshot.exit = code
            let place = Country.place(inServerName: server.name)
            var label = "\(Country.flag(code)) \(place.isEmpty ? Country.name(code) : place)"
            if tunnel.status == .connected, let latency = tunnel.report?.latency {
                label += " · \(latency) мс"
            }
            snapshot.exitLabel = label
        }
        snapshot.connected = tunnel.status == .connected
        snapshot.connecting = tunnel.status == .connecting || tunnel.status == .reasserting
        return snapshot
    }

    /// A tap on the map: its best server. A running tunnel follows it, or the
    /// interface would name an exit that isn't carrying anything.
    private func pickCountry(_ code: String) {
        let servers = store.allServers.filter { Country.code(inServerName: $0.name) == code && $0.runsOnIOS }
        guard let best = pings.best(among: servers) ?? servers.first else { return }
        choose(best)
    }

    // MARK: - Server

    private var serverBar: some View {
        HStack(spacing: 10) {
            Button {
                showingServers = true
            } label: {
                HStack(spacing: 10) {
                    if let server = store.selected {
                        FlagBadge(code: Country.code(inServerName: server.name), size: 20)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Country.place(inServerName: server.name).isEmpty
                                 ? server.name : Country.place(inServerName: server.name))
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            Text(server.kindLabel + " · " + server.address)
                                .font(.caption)
                                .foregroundStyle(Theme.inkSoft)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        PingBadge(result: pings.results[server.id], verdict: pings.verdicts[server.id])
                    } else {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(Theme.accent)
                            .frame(width: 24)
                        Text("Добавить сервер")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Spacer(minLength: 6)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.inkSoft)
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .nativeButtonStyle()
            .contextMenu { quickSwitchMenu }
            .accessibilityLabel("Сервер: \(store.selected?.name ?? "не выбран")")
            .accessibilityHint("Нажмите и удерживайте, чтобы быстро сменить сервер")

            roundButton(symbol: "bolt.fill", busy: actions.isSwitching,
                        label: "Самый быстрый сервер") {
                Task { await fastestServer() }
            }
        }
    }

    /// «Самый быстрый» с главного экрана. Итог раунда пишет Live Activity, но
    /// только когда туннель включён; с выключенным строка «Ни один сервер не
    /// ответил» возвращалась вызывающему и выбрасывалась — кнопка крутилась,
    /// останавливалась и ничего не объясняла.
    ///
    /// В канал ошибки идёт только «ничего не произошло»: `NoticeRow` подписан
    /// «Не удалось подключиться», а `statusSymbol` переезжает на предупреждение,
    /// поэтому «Выбран Нидерланды» показывать здесь нельзя — выбор и так виден
    /// по строке сервера.
    private func fastestServer() async {
        let before = store.selected?.id
        let outcome = await actions.switchToFastest(reason: .manual)
        if let outcome, !tunnel.isOn, store.selected?.id == before {
            tunnel.showError(outcome)
        }
    }

    private func roundButton(symbol: String, busy: Bool, label: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: symbol)
                }
            }
            .frame(width: 24, height: 24)
        }
        .controlSize(.large)
        .buttonBorderShape(.circle)
        .nativeButtonStyle()
        .disabled(store.allServers.isEmpty || pings.isRunning || tunnel.isBusy)
        .accessibilityLabel(label)
    }

    // MARK: - Traffic

    private var traffic: some View {
        NavigationLink {
            StatsView()
        } label: {
            TrafficStrip(
                speed: tunnel.speed,
                received: tunnel.report?.downloaded ?? 0,
                sent: tunnel.report?.uploaded ?? 0,
                history: tunnel.history,
                isLive: tunnel.status == .connected
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Открывает статистику")
    }

    // MARK: - Quick switch

    /// Press and hold the server bar: starred and recent servers, the
    /// fastest one, the full list.
    @ViewBuilder private var quickSwitchMenu: some View {
        let favorites = store.favoriteServers.filter(\.runsOnIOS)
        let recent = store.recentServers.filter { server in
            server.runsOnIOS && !favorites.contains { $0.id == server.id }
        }
        if !favorites.isEmpty {
            Section("Избранное") {
                ForEach(favorites) { quickButton($0) }
            }
        }
        if !recent.isEmpty {
            Section("Недавние") {
                ForEach(recent.prefix(4)) { quickButton($0) }
            }
        }
        Section {
            Button("Самый быстрый", systemImage: "bolt.fill") {
                Task { await fastestServer() }
            }
            .disabled(store.allServers.isEmpty || pings.isRunning || tunnel.isBusy)
            Button("Все серверы…", systemImage: "list.bullet") { showingServers = true }
        }
    }

    private func quickButton(_ server: ProxyServer) -> some View {
        let code = Country.code(inServerName: server.name)
        let place = Country.place(inServerName: server.name)
        let title = "\(code.map(Country.flag) ?? "🌐") \(place.isEmpty ? server.name : place)"
        return Button {
            choose(server)
        } label: {
            if server.id == store.selected?.id {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    /// Selects `server`; a running tunnel follows.
    private func choose(_ server: ProxyServer) {
        store.select(server.id)
        if tunnel.isOn, server.id != tunnel.activeServerID {
            Task { await actions.connect(server, waitUntilConnected: false) }
        }
    }

    // MARK: - First server

    /// Before any server: what to paste, and the two quickest ways in.
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Начните с сервера")
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .foregroundStyle(Theme.ink)
            }
            Text("Скопируйте у провайдера ссылку vless://, hy2://, vpn:// или адрес подписки и вставьте её — или отсканируйте QR-код.")
                .font(.footnote)
                .foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                PasteButton(payloadType: String.self) { strings in
                    importRequest = ImportRequest(text: strings.joined(separator: "\n"))
                }
                .buttonBorderShape(.capsule)
                .tint(Theme.accent)
                Button("QR-код", systemImage: "qrcode.viewfinder") { showingScanner = true }
                    .nativeButtonStyle()
                    .buttonBorderShape(.capsule)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .anemiaCard()
    }

    /// A scanned code: another device's bundle, or links to add.
    private func receive(_ payload: String) async {
        do {
            if let bundle = try await IncomingBundle.load(text: payload) {
                incoming = bundle
                return
            }
        } catch {
            transferError = error.localizedDescription
            return
        }
        importRequest = ImportRequest(text: payload)
    }

    // MARK: - Groups

    private var protectionGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            groupHeader("Защита")
            GlyphGroup {
                GlyphRow(symbol: "lock.shield.fill", title: "Kill switch",
                         caption: "Пока VPN не подключён, интернета нет",
                         active: store.killSwitch) {
                    Toggle("Kill switch", isOn: killSwitchBinding)
                        .labelsHidden()
                }
                RowDivider()
                GlyphRow(symbol: "personalhotspot", title: "Раздача через VPN",
                         caption: hotspotCaption,
                         active: store.hotspotThroughVPN) {
                    Toggle("Раздача через VPN", isOn: hotspotBinding)
                        .labelsHidden()
                }
                RowDivider()
                GlyphRow(symbol: "theatermasks.fill", title: "Маскировка",
                         caption: maskingCaption,
                         active: store.masking != .off) {
                    Menu {
                        Picker("Маскировка", selection: maskingBinding) {
                            ForEach(MaskingProfile.allCases, id: \.self) { profile in
                                Text(profile.russianTitle).tag(profile)
                            }
                        }
                        Divider()
                        Toggle("Подбирать для серверов", isOn: adaptiveMaskingBinding)
                    } label: {
                        HStack(spacing: 4) {
                            Text(store.masking.russianTitle)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(Theme.accent)
                    }
                }
                RowDivider()
                GlyphRow(symbol: "hand.raised.fill", title: "Без рекламы",
                         caption: "Реклама и трекеры отсекаются на уровне DNS (AdGuard)",
                         active: store.adBlock) {
                    Toggle("Без рекламы", isOn: adBlockBinding)
                        .labelsHidden()
                }
                RowDivider()
                Button {
                    showingLeakCheck = true
                } label: {
                    GlyphRow(symbol: "eye.slash.fill", title: "Проверка утечек", caption: leakCaption,
                             active: leaks.isCurrent && leaks.report?.verdict == .clean) {
                        chevron
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var connectionGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            groupHeader("Соединение")
            GlyphGroup {
                GlyphRow(symbol: "arrow.triangle.2.circlepath", title: "Автопереподключение",
                         caption: "iOS сама поднимает VPN после обрыва и смены сети",
                         active: store.autoReconnect) {
                    Toggle("Автопереподключение", isOn: autoReconnectBinding)
                        .labelsHidden()
                }
                RowDivider()
                GlyphRow(symbol: "bolt.badge.clock.fill", title: "Умное переключение",
                         caption: "Если сервер перестал пропускать трафик, Anemia сама уходит на лучший",
                         active: store.autoSwitch) {
                    Toggle("Умное переключение", isOn: autoSwitchBinding)
                        .labelsHidden()
                }
                RowDivider()
                NavigationLink {
                    SplitTunnelView()
                } label: {
                    GlyphRow(symbol: "arrow.triangle.branch", title: "Мимо VPN",
                             caption: splitTunnelCaption, active: splitTunnelCount > 0) {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.inkSoft)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// «Раздача через VPN» — это `enforceRoutes`, а iOS игнорирует его при
    /// включённом `includeAllNetworks`: строка обязана говорить об этом, а не
    /// обещать то, что kill switch уже делает сам. И выключенный тумблер не
    /// может быть подписан как работающий — трафик тогда уходит напрямую.
    private var hotspotCaption: String {
        if !store.hotspotThroughVPN {
            return "Устройства, подключённые к точке доступа, идут напрямую"
        }
        return store.killSwitch
            ? "Kill switch уже забирает весь трафик — iOS игнорирует этот флаг"
            : "Устройства, подключённые к точке доступа, идут через туннель"
    }

    /// With adaptive masking on, what it does rather than what the profile
    /// is: the menu names the profiles well enough.
    private var maskingCaption: String {
        guard store.adaptiveMasking else { return store.masking.russianSubtitle }
        var text = "Усиливается сама, если сервер блокируют, — отдельно для Wi‑Fi и сотовой сети"
        let learned = store.learnedCount
        if let kind = network.kind, learned > 0 {
            text += ". \(kind == .wifi ? "В Wi‑Fi" : "В сотовой") подобрана для \(learned) "
                + WorldMap.plural(learned, "сервера", "серверов", "серверов")
        }
        return text
    }

    private var leakCaption: String {
        guard leaks.isCurrent, let report = leaks.report else {
            return "Какой адрес видят сайты, не утекают ли DNS и IPv6"
        }
        let ip = report.exit?.ip ?? ""
        switch report.verdict {
        case .clean: return "Сайты видят \(ip) — утечек нет"
        case .leaks: return "Найдены утечки — откройте, чтобы увидеть"
        case .unknown: return "Сайты видят \(ip)"
        case .incomplete: return "Сайты видят \(ip) — \(report.missing.joined(separator: " и ")) не ответили"
        case .unprotected: return "Без VPN сайты видят \(ip)"
        case .failed: return "Не удалось проверить"
        }
    }

    private var statsGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            groupHeader("Трафик")
            GlyphGroup {
                NavigationLink {
                    StatsView()
                } label: {
                    GlyphRow(symbol: "chart.bar.fill", title: "Статистика",
                             caption: "Сегодня \(Bytes.text(stats.today.total)), за месяц \(Bytes.text(stats.month.total))",
                             active: stats.today.total > 0) {
                        chevron
                    }
                }
                .buttonStyle(.plain)
                RowDivider()
                NavigationLink {
                    SpeedTestView()
                } label: {
                    GlyphRow(symbol: "speedometer", title: "Тест скорости",
                             caption: speedCaption, active: speedTest.isRunning) {
                        chevron
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.inkSoft)
    }

    private var speedCaption: String {
        guard let last = speedTest.history.first else { return "Загрузка, отдача и пинг через VPN" }
        return "Последний: ↓ \(Speed.text(last.download))" + (last.upload.map { " · ↑ \(Speed.text($0))" } ?? "")
    }

    private func groupHeader(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.inkSoft)
            .padding(.leading, 4)
    }

    private var splitTunnelCount: Int {
        store.splitTunnel.enabled ? store.splitTunnel.activeEntries.count : 0
    }

    /// Список «Мимо VPN» при включённом kill switch на выходе WireGuard-семейства
    /// не действует: с `includeAllNetworks` iOS игнорирует исключённые маршруты,
    /// а своего обхода у AmneziaWG/WireGuard нет — об этом пишет и `TunnelPlan`, и
    /// экран «Мимо VPN». Домашний экран обязан говорить то же, иначе строка
    /// «2 адреса идут напрямую» утверждает обратное.
    private var splitTunnelInert: Bool {
        guard store.killSwitch, tunnel.isOn, let id = tunnel.activeServerID,
              let server = store.state.server(withID: id) else { return false }
        return server.proto.isWireGuardFamily
    }

    private var splitTunnelCaption: String {
        // Порядок ветвей важен: список может быть включён при нулевом числе
        // распознанных правил, и тогда правая ветка печатала бы «0 адресов — …».
        if splitTunnelCount == 0 {
            return "Весь трафик идёт через VPN"
        }
        if splitTunnelInert {
            return "\(splitTunnelCount) \(WorldMap.plural(splitTunnelCount, "адрес", "адреса", "адресов")) — с kill switch на этом выходе не действуют"
        }
        return "\(splitTunnelCount) \(WorldMap.plural(splitTunnelCount, "адрес", "адреса", "адресов")) идут напрямую"
    }

    // MARK: - Notices

    @ViewBuilder private var notices: some View {
        if let error = tunnel.lastError {
            NoticeRow(symbol: "exclamationmark.triangle.fill", title: "Не удалось подключиться",
                      message: error) {
                Button("Скопировать", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = error
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
            .onTapGesture { tunnel.clearError() }
        }
        if let server = store.selected, Country.code(inServerName: server.name) == "RU" {
            NoticeRow(symbol: "exclamationmark.triangle.fill", title: "Этот сервер в России",
                      message: "Через него блокировки не обойти — выберите зарубежный.")
        }
        if let subscription = attentionSubscription, let info = store.subscriptionInfo[subscription.id] {
            NoticeRow(symbol: "clock.badge.exclamationmark.fill",
                      title: info.expiryText ?? "Подписка заканчивается",
                      message: info.trafficText) {
                if let url = info.webPageURL ?? info.supportURL {
                    Button("Продлить") { openURL(url) }
                        .font(.footnote.weight(.semibold))
                        .nativeButtonStyle()
                }
            }
        }
    }

    /// The subscription behind the selected server, when it wants attention.
    private var attentionSubscription: Subscription? {
        guard let id = store.selected?.id, let subscription = store.subscription(containing: id),
              store.subscriptionInfo[subscription.id]?.needsAttention() == true
        else { return nil }
        return subscription
    }

    // MARK: - Bindings

    private var maskingBinding: Binding<MaskingProfile> {
        Binding(
            get: { store.masking },
            set: { profile in
                store.masking = profile
                Task { await tunnel.restartIfRunning(store: store) }
            }
        )
    }

    private var adaptiveMaskingBinding: Binding<Bool> {
        Binding(get: { store.adaptiveMasking }, set: { store.adaptiveMasking = $0 })
    }

    private var killSwitchBinding: Binding<Bool> {
        Binding(
            get: { store.killSwitch },
            set: { on in
                store.killSwitch = on
                Task { await tunnel.restartIfRunning(store: store) }
            }
        )
    }

    private var hotspotBinding: Binding<Bool> {
        Binding(
            get: { store.hotspotThroughVPN },
            set: { on in
                store.hotspotThroughVPN = on
                // С включённым kill switch iOS игнорирует `enforceRoutes`
                // совсем: рвать живые соединения ради флага, который ничего не
                // меняет, — значит выключить VPN без причины.
                guard !store.killSwitch else { return }
                Task { await tunnel.restartIfRunning(store: store) }
            }
        )
    }

    private var adBlockBinding: Binding<Bool> {
        Binding(
            get: { store.adBlock },
            set: { on in
                store.adBlock = on
                Task { await tunnel.restartIfRunning(store: store) }
            }
        )
    }

    private var autoReconnectBinding: Binding<Bool> {
        Binding(
            get: { store.autoReconnect },
            set: { on in
                store.autoReconnect = on
                Task { await tunnel.setAutoReconnect(on) }
            }
        )
    }

    private var autoSwitchBinding: Binding<Bool> {
        Binding(
            get: { store.autoSwitch },
            set: { store.autoSwitch = $0 }
        )
    }
}

/// A link handed to the app from outside, waiting in the import sheet.
private struct ImportRequest: Identifiable {
    let id = UUID()
    let text: String
}

extension NEVPNStatus {
    var title: String {
        switch self {
        case .invalid: "Не настроен"
        case .disconnected: "Отключено"
        case .connecting: "Подключение…"
        case .connected: "Подключено"
        case .reasserting: "Переподключение…"
        case .disconnecting: "Отключение…"
        @unknown default: "Неизвестно"
        }
    }
}

#Preview {
    let model = AppModel.shared
    ContentView()
        .environment(model.tunnel)
        .environment(model.store)
        .environment(model.liveActivity)
        .environment(model.pings)
        .environment(model.actions)
        .environment(model.stats)
        .environment(model.speedTest)
        .environment(model.network)
        .environment(model.leaks)
        .environment(model.alerts)
        .environment(AppRouter.shared)
        .tint(Theme.accent)
}
