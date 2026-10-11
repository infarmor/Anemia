import LoaderCore
import PhotosUI
import SwiftUI

/// The server picker: manual servers, then each subscription with what its
/// panel says about it. The check measures every server and says which ones
/// actually carry traffic.
struct ServersView: View {
    @Environment(ServerStore.self) private var store
    @Environment(TunnelController.self) private var tunnel
    @Environment(PingController.self) private var pings
    @Environment(QuickActions.self) private var actions
    @Environment(\.dismiss) private var dismiss

    @State private var importPrefill: String?
    @State private var showingImport = false
    @State private var showingScanner = false
    @State private var photo: PhotosPickerItem?
    @State private var photoProblem: String?
    @State private var fastestOutcome: String?
    @State private var incoming: IncomingBundle?
    @State private var query = ""
    @AppStorage("serversSortedByPing") private var sortedByPing = false

    var body: some View {
        NavigationStack {
            List {
                if !trimmedQuery.isEmpty {
                    let found = ordered(store.allServers.filter(matches))
                    Section(found.isEmpty ? "Ничего не нашлось" : "Найдено: \(found.count)") {
                        ForEach(found) { server in
                            row(server)
                        }
                    }
                    .listRowBackground(Theme.card)
                } else {
                    groupedSections
                }

                if let photoProblem {
                    Section {
                        Text(photoProblem)
                            .font(.footnote)
                            .foregroundStyle(Theme.accent)
                    }
                    .listRowBackground(Theme.card)
                }
                if let fastestOutcome {
                    Section {
                        Text(fastestOutcome)
                            .font(.footnote)
                            .foregroundStyle(Theme.accent)
                    }
                    .listRowBackground(Theme.card)
                }
            }
            .anemiaList()
            .searchable(text: $query, prompt: "Страна, город или адрес")
            .overlay {
                if store.allServers.isEmpty {
                    ContentUnavailableView {
                        Label("Серверов нет", systemImage: "server.rack")
                    } description: {
                        Text("Добавьте ссылку, адрес подписки или отсканируйте QR-код.")
                    } actions: {
                        Button("Добавить", systemImage: "plus") { showingImport = true }
                            .nativeButtonStyle(prominent: true)
                        Button("Сканировать QR", systemImage: "qrcode.viewfinder") { showingScanner = true }
                            .nativeButtonStyle()
                    }
                }
            }
            .navigationTitle("Серверы")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .refreshable { await store.refreshAll() }
            .sheet(isPresented: $showingImport) {
                ImportSheet(prefill: importPrefill)
            }
            .sheet(isPresented: $showingScanner) {
                QRScannerSheet { payload in
                    Task { await receive(payload) }
                }
            }
            .sheet(item: $incoming) { incoming in
                SyncImportSheet(bundle: incoming.bundle)
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task { await readPhoto(item) }
            }
        }
    }

    /// Starred servers, manual ones, then each subscription. A starred server
    /// shows once — in «Избранное»: the same id twice in one List makes
    /// SwiftUI's rows behave unpredictably (ghost rows after a delete, the
    /// ping badge of another row).
    @ViewBuilder private var groupedSections: some View {
        let favorites = store.favoriteServers
        if !favorites.isEmpty {
            Section("Избранное") {
                ForEach(ordered(favorites)) { server in
                    row(server)
                }
            }
            .listRowBackground(Theme.card)
        }

        let manual = store.state.servers.filter { !store.isFavorite($0) }
        if !manual.isEmpty {
            Section("Мои серверы") {
                // Deleting needs the stored order, so manual servers
                // keep it even when the list is sorted by speed.
                ForEach(manual) { server in
                    row(server)
                }
                .onDelete { store.removeServers(ids: $0.map { manual[$0].id }) }
            }
            .listRowBackground(Theme.card)
        }

        ForEach(store.state.subscriptions) { subscription in
            Section {
                if let info = store.subscriptionInfo[subscription.id] {
                    SubscriptionInfoRow(info: info)
                }
                ForEach(ordered(subscription.servers.filter { !store.isFavorite($0) })) { server in
                    row(server)
                }
            } header: {
                SubscriptionHeader(subscription: subscription)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let problem = store.refreshErrors[subscription.id] {
                        Text(problem)
                            .foregroundStyle(Theme.accent)
                    }
                    if let updated = subscription.lastUpdated {
                        Text("Обновлено \(updated.formatted(.relative(presentation: .named).locale(Locale(identifier: "ru_RU"))))")
                    }
                }
            }
            .listRowBackground(Theme.card)
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// By name, country (in Russian or English), protocol or address.
    private func matches(_ server: ProxyServer) -> Bool {
        let code = Country.code(inServerName: server.name)
        let fields = [server.name, server.address, server.kindLabel, code ?? "",
                      code.map(Country.name) ?? "",
                      code.flatMap { Locale(identifier: "en_US").localizedString(forRegionCode: $0) } ?? ""]
        return fields.contains { $0.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Готово") { dismiss() }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button("Проверить через прокси", systemImage: "checkmark.seal") {
                    Task { await pings.checkAll(store.allServers) }
                }
                .disabled(pings.isRunning || store.allServers.isEmpty)
                Button("Только пинг", systemImage: "gauge.with.dots.needle.67percent") {
                    Task { await pings.pingAll(store.allServers) }
                }
                .disabled(pings.isRunning || store.allServers.isEmpty)
                Divider()
                Toggle("Сначала быстрые", isOn: $sortedByPing)
            } label: {
                if pings.isRunning {
                    ProgressView()
                } else {
                    Label("Проверка", systemImage: "gauge.with.dots.needle.67percent")
                }
            }
            Menu {
                Button("Ссылка или подписка", systemImage: "link") {
                    importPrefill = nil
                    showingImport = true
                }
                Button("Сканировать QR", systemImage: "qrcode.viewfinder") {
                    showingScanner = true
                }
                PhotosPicker(selection: $photo, matching: .images) {
                    Label("QR из Фото", systemImage: "photo.on.rectangle")
                }
            } label: {
                Label("Добавить", systemImage: "plus")
            }
        }
    }

    /// The count and the one action worth a permanent button.
    private var bottomBar: some View {
        HStack(spacing: 10) {
            // Grey for the count only: on the whole bar it would also grey
            // the prominent button's label.
            Group {
                if pings.isRunning, let progress = pings.progress {
                    ProgressView()
                        .controlSize(.small)
                    Text("Проверено \(progress.done) из \(progress.total)")
                } else if pings.isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text("Измеряю…")
                } else {
                    let count = store.allServers.count
                    Text("\(count) \(WorldMap.plural(count, "сервер", "сервера", "серверов"))")
                }
            }
            .foregroundStyle(Theme.inkSoft)
            Spacer(minLength: 8)
            Button {
                Task {
                    // Итог остаётся на экране: лист закрывался в любом случае, и
                    // «Ни один сервер не ответил», и отказ занятого туннеля
                    // уезжали под него — пользователь видел только закрывшийся
                    // список.
                    fastestOutcome = await actions.switchToFastest(reason: .manual)
                    if tunnel.activeServerID == store.selected?.id { dismiss() }
                }
            } label: {
                Label("Самый быстрый", systemImage: "bolt.fill")
            }
            .nativeButtonStyle(prominent: true)
            // `tunnel.isBusy` — тот же отказ, что и в «Серверах» на главном
            // экране: раунд посреди переключения передвигает выбор, а старт
            // «занято» не состоит.
            .disabled(store.allServers.isEmpty || pings.isRunning || actions.isSwitching || tunnel.isBusy)
        }
        .font(.footnote)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Rows

    private func row(_ server: ProxyServer) -> some View {
        Button {
            // Выбор под выходом, которого на iOS нет, `QuickActions.connect`
            // уже отказывает — но сам `select` здесь случался до отказа:
            // экран оставался с выбранной строкой, которую нельзя подключить,
            // а `store.selected` отдаёт её, пока id не исчезнет из списка.
            guard server.runsOnIOS else {
                tunnel.showError(TunnelController.unsupportedServerMessage)
                return
            }
            store.select(server.id)
            // Only a running tunnel follows the choice; a stopped one picks
            // it up at the next start.
            if tunnel.isOn, server.id != tunnel.activeServerID {
                Task { await actions.connect(server, waitUntilConnected: false) }
            }
        } label: {
            ServerRow(server: server,
                      isSelected: server.id == store.selected?.id,
                      ping: pings.results[server.id],
                      verdict: pings.verdicts[server.id],
                      stability: pings.stability(server.id),
                      learnedMasking: store.adaptiveMasking ? store.learnedMasking(for: server) : nil,
                      isFavorite: store.isFavorite(server))
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                store.toggleFavorite(server)
            } label: {
                if store.isFavorite(server) {
                    Label("Убрать из избранного", systemImage: "star.slash")
                } else {
                    Label("В избранное", systemImage: "star.fill")
                }
            }
            .tint(Theme.accent)
        }
        .contextMenu {
            Button("Подключить", systemImage: "power") {
                Task { await actions.connect(server, waitUntilConnected: false) }
            }
            .disabled(!server.runsOnIOS)
            // Тот же отказ, что и у строки: выбор под неподдерживаемым выходом
            // оставил бы приложение с тумблером, который ничего не подключает.
            Button("Выбрать", systemImage: "checkmark") { store.select(server.id) }
                .disabled(!server.runsOnIOS)
            Button(store.isFavorite(server) ? "Убрать из избранного" : "В избранное",
                   systemImage: store.isFavorite(server) ? "star.slash" : "star") {
                store.toggleFavorite(server)
            }
            if let learned = store.learnedMasking(for: server) {
                Button("Сбросить маскировку «\(learned.russianTitle)»", systemImage: "theatermasks") {
                    store.learn(nil, for: server)
                    pings.forget(server.id)
                }
            }
            if let index = store.state.servers.firstIndex(where: { $0.id == server.id }) {
                Divider()
                Button("Удалить", systemImage: "trash", role: .destructive) {
                    store.removeServers(at: IndexSet(integer: index))
                }
            }
        }
    }

    private func ordered(_ servers: [ProxyServer]) -> [ProxyServer] {
        guard sortedByPing else { return servers }
        return servers.enumerated()
            .sorted { lhs, rhs in
                let (left, right) = (pings.sortKey(lhs.element), pings.sortKey(rhs.element))
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
    }

    private func readPhoto(_ item: PhotosPickerItem) async {
        photoProblem = nil
        photo = nil
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            photoProblem = "Не удалось открыть снимок"
            return
        }
        // `CIDetectorAccuracyHigh` по всему снимку — секунды на кадре с 12 МП,
        // а `readPhoto` вызывается из `.onChange` на MainActor: всё это время
        // лист выбора не отвечал, и непонятно, ищет он или завис.
        let found = await Task.detached(priority: .userInitiated) {
            QRReader.payloads(in: data)
        }.value
        guard let payload = found.first else {
            photoProblem = "На снимке нет QR-кода"
            return
        }
        await receive(payload)
    }

    /// A scanned code: another device's bundle, or links to add.
    private func receive(_ payload: String) async {
        do {
            if let bundle = try await IncomingBundle.load(text: payload) {
                incoming = bundle
                return
            }
        } catch {
            photoProblem = error.localizedDescription
            return
        }
        importPrefill = payload
        showingImport = true
    }
}

/// What the panel says about a subscription: traffic left and how long.
private struct SubscriptionInfoRow: View {
    let info: SubscriptionInfo
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let traffic = info.trafficText {
                HStack {
                    Text(traffic)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 8)
                    if let fraction = info.usedFraction {
                        // Вниз: все пороги в приложении — `>= 0.9`
                        // (`needsAttention`, план напоминаний, фильтр `warned`),
                        // а округление вверх показывало «90%» чёрным по
                        // 0,8999 — то есть там, где ничего ещё не должно
                        // произойти, — и тот же «90%» потом появлялся рыжим
                        // вместе с обещанным напоминанием.
                        Text("\(Int((fraction * 100).rounded(.down)))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.inkSoft)
                    }
                }
            }
            if let fraction = info.usedFraction {
                ProgressView(value: fraction)
                    .tint(fraction > 0.9 ? Theme.accent : Theme.ink)
            }
            if let expiry = info.expiryText {
                Label(expiry, systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(info.needsAttention() ? Theme.accent : Theme.inkSoft)
            }
            if let announcement = info.announcement {
                Text(announcement)
                    .font(.caption)
                    .foregroundStyle(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if info.supportURL != nil || info.webPageURL != nil {
                HStack(spacing: 14) {
                    if let url = info.webPageURL {
                        Button("Личный кабинет", systemImage: "person.crop.circle") { openURL(url) }
                    }
                    if let url = info.supportURL {
                        Button("Поддержка", systemImage: "lifepreserver") { openURL(url) }
                    }
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SubscriptionHeader: View {
    @Environment(ServerStore.self) private var store
    let subscription: Subscription

    var body: some View {
        HStack {
            Text(store.displayName(of: subscription))
                .lineLimit(1)
            if !subscription.tlsProtected {
                Image(systemName: "lock.open.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Без TLS: автоматически не обновляется")
            }
            Spacer()
            if store.refreshing.contains(subscription.id) {
                ProgressView()
            } else {
                Menu {
                    Button("Обновить", systemImage: "arrow.clockwise") {
                        Task { await store.refresh(subscription.id) }
                    }
                    Button("Удалить подписку", systemImage: "trash", role: .destructive) {
                        store.removeSubscription(subscription.id)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .imageScale(.large)
                }
                .accessibilityLabel("Действия с подпиской")
            }
        }
    }
}

/// Paste or type a link, a subscription address or a base64 list.
struct ImportSheet: View {
    var prefill: String?

    @Environment(ServerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var working = false
    @State private var incoming: IncomingBundle?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("vless://, hy2://, vpn:// или https://…", text: $text, axis: .vertical)
                        .lineLimit(3...10)
                        .font(.footnote.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    PasteButton(payloadType: String.self) { strings in
                        text = strings.joined(separator: "\n")
                    }
                } footer: {
                    Text("Ссылки на серверы, по одной в строке, или адрес подписки. Подписку потом можно обновлять из списка серверов.")
                }
                .listRowBackground(Theme.card)

                if let error = store.importError {
                    Section {
                        Text(error)
                            .foregroundStyle(Theme.accent)
                    }
                    .listRowBackground(Theme.card)
                }
            }
            .anemiaList()
            .navigationTitle("Новый сервер")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Добавить") {
                            // Разбор идёт вне главного актора, поэтому кнопка
                            // просто запускает задачу: `working` и так показывает
                            // занятость, а мегибайтная ссылка не вешает шторку.
                            let payload = text
                            Task {
                                do {
                                    if let bundle = try await IncomingBundle.load(text: payload) {
                                        incoming = bundle
                                        return
                                    }
                                } catch {
                                    store.importError = error.localizedDescription
                                    return
                                }
                                working = true
                                let added = await store.importText(payload)
                                working = false
                                if added { dismiss() }
                            }
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .onAppear {
            store.importError = nil
            if let prefill, text.isEmpty { text = prefill }
        }
        .sheet(item: $incoming, onDismiss: { dismiss() }) { incoming in
            SyncImportSheet(bundle: incoming.bundle)
        }
    }
}
