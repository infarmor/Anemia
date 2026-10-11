import LoaderCore
import SwiftUI

/// "Мимо VPN": addresses and sites that leave through the regular network.
struct SplitTunnelView: View {
    @Environment(ServerStore.self) private var store
    @Environment(TunnelController.self) private var tunnel
    @State private var text = ""
    @State private var enabled = true
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                Toggle(isOn: $enabled) {
                    Label("Раздельное туннелирование", systemImage: "arrow.triangle.branch")
                }
            } footer: {
                Text("Эти адреса и сайты открываются напрямую, мимо VPN. Домен включает все поддомены, «ru» — все сайты в зоне .ru.")
            }
            .listRowBackground(Theme.card)

            Section {
                // Grows with the list, unlike a TextEditor in a List row.
                TextField("gosuslugi.ru\n192.168.10.0/24\nсбербанк.рф", text: $text, axis: .vertical)
                    .lineLimit(8...)
                    .font(.footnote.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Добавить российские сервисы", systemImage: "plus.circle") {
                    addRussianServices()
                }
            } header: {
                Text("Адреса и сайты")
            } footer: {
                Text(summary)
            }
            .listRowBackground(Theme.card)

            if !parsed.rejected.isEmpty {
                Section("Не распознано") {
                    // `line` не уникален: парсер вычитает дубликаты только у
                    // принятых правил, а отказ возвращает по одному на строку,
                    // поэтому вставленный дважды «госу» дал бы List два
                    // одинаковых идентификатора — SwiftUI на этом rows ведёт
                    // себя непредсказуемо.
                    ForEach(Array(parsed.rejected.enumerated()), id: \.offset) { _, rejection in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rejection.line)
                                .font(.footnote.monospaced())
                            Text(rejection.russianReason)
                                .font(.caption)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
                .listRowBackground(Theme.card)
            }

            Section {
                Label {
                    Text(wireGuardNote)
                        .font(.footnote)
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Theme.accent)
                }
            }
            .listRowBackground(Theme.card)
        }
        .anemiaList()
        .navigationTitle("Мимо VPN")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            text = store.splitTunnel.entries.joined(separator: "\n")
            enabled = store.splitTunnel.enabled
        }
        .onChange(of: text) { scheduleSave() }
        .onChange(of: enabled) { save() }
        .onDisappear {
            saveTask?.cancel()
            save()
        }
    }

    /// The list used to be committed only when the screen closed — force-quit
    /// the app from here (routine after editing VPN settings) and the entries
    /// were gone. Saving per keystroke would restart the running tunnel every
    /// time, so it goes a beat after the typing stops.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private var parsed: SplitTunnelParser.Result {
        SplitTunnelParser.parse(text: text)
    }

    private var summary: String {
        let count = parsed.entries.count
        let rules = count == 0 ? "Список пуст." : "Правил: \(count)."
        return rules + " По одному адресу, сети или домену в строке; # — комментарий. Изменения применятся при следующем подключении, а если VPN включён — сразу."
    }

    /// WireGuard routes by address only, and the kill switch takes even that away.
    private var wireGuardNote: String {
        if store.killSwitch {
            return "С kill switch iOS не выпускает трафик мимо туннеля у серверов AmneziaWG и WireGuard: для них этот список не действует. У VLESS, Hysteria и остальных он работает."
        }
        return "У AmneziaWG и WireGuard мимо VPN идут только адреса и отдельные сайты — их IP узнаются при подключении. Целые зоны вроде «ru» действуют у VLESS, Hysteria и остальных."
    }

    /// .ru, .рф, .su plus the Russian services that live outside those zones.
    private static let russianServices = [
        "# Российские сервисы",
        "ru", "рф", "su",
        "vk.com", "vk.me", "vkuser.net", "userapi.com", "mycdn.me",
        "yandex.com", "yandex.net", "yastatic.net",
        "2gis.com", "sberbank.com",
    ]

    private func addRussianServices() {
        let present = Set(text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        let missing = Self.russianServices.filter { !present.contains($0) }
        guard !missing.isEmpty else { return }
        text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + missing.joined(separator: "\n")
    }

    private func save() {
        // One destination per stored line — the form the tunnel parses —
        // while comment lines stay for the reader.
        var lines: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                lines.append(line)
                continue
            }
            let code = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            lines += code.split(whereSeparator: { ",; \t".contains($0) }).map(String.init)
        }
        let rules = SplitTunnelRules(enabled: enabled, entries: lines)
        guard rules != store.splitTunnel else { return }
        // Перезапуск рвёт все живые соединения, а список выше хранит и
        // комментарии, и то, что парсер отверг. «госу» → пауза → «slugi.ru»,
        // или опечатка в маске (`192.168.10.0/33`) меняют только хранимые
        // строки: эффективные правила остаются теми же, и поднимать туннель
        // ради них — значит уронить туннель.
        let before = SplitTunnelParser.parse(text: store.splitTunnel.entries.joined(separator: "\n")).entries
        let effectiveChanged = enabled != store.splitTunnel.enabled || parsed.entries != before
        store.splitTunnel = rules
        guard effectiveChanged else { return }
        Task { await tunnel.restartIfRunning(store: store) }
    }
}

extension TunnelController {
    /// A running tunnel reads its settings at start: restart it to apply them.
    func restartIfRunning(store: ServerStore) async {
        guard isOn else { return }
        let server = activeServerID.flatMap { store.state.server(withID: $0) } ?? store.selected
        guard let server else { return }
        await connect(server)
    }
}
