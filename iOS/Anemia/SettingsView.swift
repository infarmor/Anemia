import SwiftUI
import UserNotifications

/// Everything that isn't the connection itself: the Lock Screen activity,
/// subscriptions, diagnostics and what this build is made of.
struct SettingsView: View {
    @Environment(ServerStore.self) private var store
    @Environment(LiveActivityController.self) private var liveActivity
    @Environment(TunnelController.self) private var tunnel
    @Environment(SubscriptionAlerts.self) private var alerts
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))

                Section {
                    Toggle(isOn: liveActivityBinding) {
                        Label("Live Activity", systemImage: "platter.filled.top.iphone")
                    }
                    if liveActivity.isEnabled {
                        Toggle(isOn: backgroundSpeedBinding) {
                            Label("Скорость в фоне", systemImage: "speedometer")
                        }
                    }
                } header: {
                    Text("Dynamic Island")
                } footer: {
                    Text(liveActivityFooter)
                }
                .listRowBackground(Theme.card)

                Section {
                    Toggle(isOn: autoRefreshBinding) {
                        Label("Обновлять подписки сами", systemImage: "arrow.clockwise")
                    }
                    Toggle(isOn: remindersBinding) {
                        Label("Напоминать об окончании", systemImage: "bell.badge")
                    }
                    if alerts.isEnabled, alerts.permission == .provisional || alerts.permission == .notDetermined {
                        Button {
                            Task { await alerts.askForBanners() }
                        } label: {
                            Label("Показывать баннером", systemImage: "bell.circle")
                        }
                    } else if alerts.isEnabled, alerts.permission == .denied {
                        Button {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                        } label: {
                            Label("Разрешить уведомления", systemImage: "gear")
                        }
                    }
                } header: {
                    Text("Подписки")
                } footer: {
                    Text(subscriptionsFooter)
                }
                .listRowBackground(Theme.card)

                TransferSection()

                Section {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Диагностика", systemImage: "stethoscope")
                    }
                } footer: {
                    Text("Состояние движка, лог и подпись — если что-то не работает.")
                }
                .listRowBackground(Theme.card)

                Section {
                    LabeledContent("Версия", value: AppBundle.version)
                    LabeledContent("Выбор сервера", value: Kxc.shared.status)
                    LabeledContent("Движки") {
                        Text(tunnel.report?.engineVersion ?? "Xray + AmneziaWG")
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(Theme.inkSoft)
                    }
                } header: {
                    Text("О приложении")
                } footer: {
                    Text("Anemia для iPhone: Xray-core и AmneziaWG в одном движке. Siri: «Включи Anemia», «Самый быстрый сервер в Anemia».")
                }
                .listRowBackground(Theme.card)
            }
            .anemiaList()
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .task { await alerts.refreshPermission() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image("AnemiaMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .foregroundStyle(Color.white)
                .frame(width: 54, height: 54)
                .background(Theme.accent.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Anemia")
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSoft)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private var subtitle: String {
        let servers = store.allServers.count
        let count = "\(servers) \(WorldMap.plural(servers, "сервер", "сервера", "серверов"))"
        return tunnel.status == .connected ? "Защищено · \(count)" : count
    }

    private var liveActivityFooter: String {
        if !liveActivity.systemAllows {
            return "Live Activity для Anemia выключены в Настройках iOS: Anemia → Live Activity."
        }
        if !liveActivity.isEnabled {
            return "Кольцо сессии, страна, скорость, график и кнопки в Dynamic Island, пока VPN включён; на экране блокировки — одна строка."
        }
        return liveActivity.updatesInBackground
            ? "Кольцо, страна, живая скорость с графиком, трафик и пинг. Чтобы всё это обновлялось, Anemia остаётся активной в фоне (беззвучное аудио) — это расходует батарею."
            : "Скорость обновляется, только пока Anemia открыта; в остальное время остров показывает время сессии."
    }

    private var liveActivityBinding: Binding<Bool> {
        Binding(get: { liveActivity.isEnabled }, set: { liveActivity.isEnabled = $0 })
    }

    private var backgroundSpeedBinding: Binding<Bool> {
        Binding(get: { liveActivity.updatesInBackground }, set: { liveActivity.updatesInBackground = $0 })
    }

    private var subscriptionsFooter: String {
        var text = "Подписки обновляются при запуске Anemia и каждые 6 часов, пока она работает — или так часто, как просит панель."
        // `refreshIsDue` не пропускает панель без TLS (её ответ пишет тот, кто
        // у маршрута), а «Обновлено …» под списком с тех пор только стареет —
        // здесь это надо назвать, иначе обещание «каждые 6 часов» неверно.
        if store.state.subscriptions.contains(where: { !$0.tlsProtected }) {
            text += " Ссылок без HTTPS автомат не касается: их обновляй вручную — так безопаснее."
        }
        guard alerts.isEnabled else { return text }
        text += " За 3 дня и за день до конца подписки и когда трафика остаётся 10 %, придёт напоминание"
        switch alerts.permission {
        case .denied: text += " — но уведомления для Anemia выключены в Настройках iOS."
        case .provisional, .notDetermined: text += " — пока тихо, в Центр уведомлений."
        default: text += "."
        }
        return text
    }

    private var remindersBinding: Binding<Bool> {
        Binding(get: { alerts.isEnabled }, set: { alerts.isEnabled = $0 })
    }

    private var autoRefreshBinding: Binding<Bool> {
        Binding(get: { store.autoRefreshSubscriptions }, set: { store.autoRefreshSubscriptions = $0 })
    }
}
