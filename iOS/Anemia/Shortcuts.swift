import AppIntents
import LoaderCore

// Siri and the Shortcuts app. These intents belong to the app alone, so iOS
// runs them in its process (launching it in the background if needed); being
// LiveActivityIntents too, they may start the Live Activity from there.

struct ConnectVPNShortcut: AppIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Включить VPN"
    static let description = IntentDescription("Подключает Anemia к выбранному серверу или к указанному.")

    @Parameter(title: "Сервер")
    var server: ServerEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Включить VPN через \(\.$server)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        if let chosen = server.flatMap({ model.store.state.server(withID: $0.id) }) {
            await model.actions.connect(chosen, waitUntilConnected: true)
        } else {
            await model.actions.connectSelected(waitUntilConnected: true)
        }
        let tunnel = model.tunnel
        guard tunnel.status == .connected else {
            let reason = tunnel.lastError?.components(separatedBy: "\n").first ?? "VPN не подключился"
            return .result(dialog: "Не получилось: \(reason)")
        }
        let name = tunnel.activeServerID.flatMap { model.store.state.server(withID: $0) }?.name ?? "сервер"
        return .result(dialog: "Anemia подключена: \(name)")
    }
}

struct DisconnectVPNShortcut: AppIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Выключить VPN"
    static let description = IntentDescription("Отключает Anemia. Автопереподключение его не вернёт.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await AppModel.shared.actions.disconnect()
        return .result(dialog: "Anemia отключена")
    }
}

struct FastestServerShortcut: AppIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Самый быстрый сервер"
    static let description = IntentDescription(
        "Проверяет все серверы через прокси и выбирает самый быстрый. Включённый VPN сразу переходит на него."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let actions = AppModel.shared.actions
        // The round probes every server — tens of seconds a batch, minutes on
        // a big panel — while an intent gets seconds. Starting it and letting
        // the Live Activity report the outcome is the only version that
        // works; awaiting it makes Siri fail every time.
        Task { await actions.switchToFastest(reason: .manual) }
        return .result(dialog: "Ищу самый быстрый сервер, результат покажет Live Activity.")
    }
}

struct VPNStatusShortcut: AppIntent {
    static let title: LocalizedStringResource = "Состояние VPN"
    static let description = IntentDescription("Сообщает, включён ли VPN Anemia. Результат можно использовать в автоматизациях.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let model = AppModel.shared
        // The first read of the configuration waits on iOS's "Allow VPN
        // configurations" prompt, which a background launch can't show — the
        // load would simply never come back and Siri would report a failure
        // for a question with an answer.
        //
        // A real deadline, not a task group: the group's body waits for the
        // load child to unwind, and that child is bridged from a completion
        // handler `cancelAll()` can't reach — the intent would hang instead of
        // falling through to the "yet to answer" dialog below.
        let load = Task { await model.tunnel.loadIfNeeded() }
        let loaded = await AsyncRace.withTimeout(seconds: 2, fallback: false) {
            await load.value
            return true
        }
        if !loaded { load.cancel() }
        guard model.tunnel.isLoaded else {
            return .result(value: false, dialog: "Anemia ещё не ответила — открой приложение и разреши VPN-подключения")
        }
        let status = model.tunnel.status
        let on = status == .connected
        let name = model.tunnel.activeServerID.flatMap { model.store.state.server(withID: $0) }?.name
        // Подключение ещё не `.connected`, но и не «выключен»: тайлик Пункта
        // управления в этот момент говорит «Включён», виджет — «Подключение…»,
        // а Siri на тот же статус отвечала «VPN выключен». Значение для
        // автоматизаций остаётся строгим (`false`, пока не поехал трафик) —
        // врать ему хуже, чем словесно; а вот диалог должен быть правдой.
        if !on, model.tunnel.isOn {
            return .result(value: false, dialog: "VPN подключается: \(name ?? "Anemia")")
        }
        let dialog: IntentDialog = on ? "VPN включён: \(name ?? "Anemia")" : "VPN выключен"
        return .result(value: on, dialog: dialog)
    }
}

struct AnemiaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectVPNShortcut(),
            phrases: ["Включи \(.applicationName)", "Подключи \(.applicationName)", "Включи VPN \(.applicationName)"],
            shortTitle: "Включить VPN",
            systemImageName: "lock.shield"
        )
        AppShortcut(
            intent: DisconnectVPNShortcut(),
            phrases: ["Выключи \(.applicationName)", "Отключи \(.applicationName)"],
            shortTitle: "Выключить VPN",
            systemImageName: "shield.slash"
        )
        AppShortcut(
            intent: FastestServerShortcut(),
            phrases: ["Самый быстрый сервер в \(.applicationName)", "Ускорь \(.applicationName)"],
            shortTitle: "Самый быстрый",
            systemImageName: "bolt"
        )
        AppShortcut(
            intent: VPNStatusShortcut(),
            phrases: ["Включён ли \(.applicationName)", "Состояние \(.applicationName)"],
            shortTitle: "Состояние VPN",
            systemImageName: "shield.lefthalf.filled"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .orange
}

/// A server, for Shortcuts' pickers.
struct ServerEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Сервер"
    static let defaultQuery = ServerQuery()

    var id: UUID
    var name: String
    var kind: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(kind)")
    }

    init(_ server: ProxyServer) {
        id = server.id
        name = server.name
        kind = server.kindLabel
    }
}

struct ServerQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ServerEntity] {
        let store = AppModel.shared.store
        return identifiers.compactMap { store.state.server(withID: $0) }.map(ServerEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [ServerEntity] {
        AppModel.shared.store.allServers.filter(\.runsOnIOS).map(ServerEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [ServerEntity] {
        AppModel.shared.store.allServers
            .filter { $0.runsOnIOS && $0.name.localizedCaseInsensitiveContains(string) }
            .map(ServerEntity.init)
    }
}
