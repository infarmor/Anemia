import LoaderCore
import SwiftUI

/// "Проверка утечек": the address sites see, whether IPv6 and DNS stay in
/// the tunnel, and for comparison the address without the VPN.
struct LeakCheckView: View {
    @Environment(LeakChecker.self) private var checker

    var body: some View {
        List {
            Section {
                summary
            }
            .listRowBackground(Theme.card)

            if let report = checker.report {
                Section("Сайты видят") {
                    if let exit = report.exit {
                        AddressRow(info: exit)
                    } else {
                        Text("Адрес узнать не удалось")
                            .foregroundStyle(Theme.inkSoft)
                    }
                }
                .listRowBackground(Theme.card)

                if report.serverID != nil, report.exit != nil {
                    Section("Проверки") {
                        tunnelRow(report)
                        ipv6Row(report)
                        dnsRow(report)
                    }
                    .listRowBackground(Theme.card)
                }

                if let servers = report.dns, !servers.isEmpty {
                    Section {
                        ForEach(DNSGroup.of(servers, leaking: report.dnsLeak)) { group in
                            DNSGroupRow(group: group)
                        }
                    } header: {
                        Text("DNS-серверы")
                    } footer: {
                        Text("Они отвечают на запросы этого iPhone. Если они в вашей стране, провайдер может видеть, какие сайты вы открываете.")
                    }
                    .listRowBackground(Theme.card)
                }

                if report.serverID != nil, let direct = report.direct {
                    Section {
                        AddressRow(info: direct)
                    } header: {
                        Text("Без VPN")
                    } footer: {
                        Text("Адрес от вашего провайдера: его сайты видели бы без VPN. Узнаёт расширение VPN — его запросы идут мимо туннеля.")
                    }
                    .listRowBackground(Theme.card)
                }
            }

            Section {
            } footer: {
                Text("Адрес сообщает ip.sb, DNS-серверы — bash.ws: на время проверки они видят адрес выхода и несколько тестовых запросов.")
            }
        }
        .anemiaList()
        .navigationTitle("Проверка утечек")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Проверить снова", systemImage: "arrow.clockwise") {
                    Task { await checker.run() }
                }
                .disabled(checker.isRunning)
            }
        }
        .refreshable { await checker.run() }
        .task {
            if !checker.isCurrent { await checker.run() }
        }
    }

    // MARK: - Summary

    private var summary: some View {
        HStack(spacing: 14) {
            ZStack {
                if checker.isRunning {
                    ProgressView()
                } else {
                    Image(systemName: look.symbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(look.filled ? Color.white : Theme.inkSoft)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 50, height: 50)
            .background(look.filled && !checker.isRunning ? AnyShapeStyle(Theme.accent.gradient) : AnyShapeStyle(Theme.idle),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(look.title)
                    .font(.system(size: 22, weight: .medium, design: .serif))
                    .foregroundStyle(Theme.ink)
                Text(look.detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .animation(Theme.spring, value: look.title)
    }

    private var look: (symbol: String, filled: Bool, title: String, detail: String) {
        if let step = checker.step {
            return ("magnifyingglass", false, "Проверяю…", step)
        }
        guard let report = checker.report else {
            return ("questionmark.circle", false, "Не проверено", "Нажмите ↻, чтобы проверить.")
        }
        switch report.verdict {
        case .clean:
            return ("checkmark.shield.fill", true, "Утечек нет",
                    "Сайты видят адрес сервера, а DNS и IPv6 не выдают ваш настоящий.")
        case .leaks:
            return ("exclamationmark.shield.fill", true, "Найдены утечки", leakSummary(report))
        case .unknown:
            return ("shield.lefthalf.filled", true, "Адрес скрыт",
                    report.sameCountryAsHome
                    ? "Выход в вашей стране — по стране не отличить ваш адрес от адреса сервера, поэтому DNS и IPv6 не сравнивались."
                    : "Сравнить с адресом без VPN не удалось: расширение VPN не ответило.")
        case .incomplete:
            return ("shield.lefthalf.filled", true, "Адрес скрыт",
                    "Нет ответа: \(report.missing.joined(separator: " и ")) — проверить их на утечки не удалось.")
        case .unprotected:
            return ("shield.slash", false, "VPN выключен",
                    "Сайты видят ваш настоящий адрес. Включите VPN и проверьте снова.")
        case .failed:
            return ("exclamationmark.triangle.fill", false, "Не удалось проверить",
                    "ip.sb не ответил — проверьте подключение к интернету.")
        }
    }

    private func leakSummary(_ report: LeakChecker.Report) -> String {
        var parts: [String] = []
        if report.bypassed { parts.append("трафик идёт мимо VPN") }
        if report.ipv6Leak != nil { parts.append("IPv6 выдаёт ваш адрес") }
        if !report.dnsLeak.isEmpty { parts.append("DNS-запросы видит провайдер") }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst() + "."
    }

    // MARK: - Checks

    private func tunnelRow(_ report: LeakChecker.Report) -> some View {
        let state: CheckRow.State = report.direct == nil ? .unknown : (report.bypassed ? .failed : .passed)
        let caption = switch state {
        case .passed: "Адрес выхода не ваш"
        case .failed: "Сайты видят ваш настоящий адрес"
        case .unknown: "Не с чем сравнить"
        }
        return CheckRow(symbol: "arrow.triangle.merge", title: "Трафик через VPN", caption: caption, state: state)
    }

    private func ipv6Row(_ report: LeakChecker.Report) -> some View {
        // `findings` при совпавшей стране не сравнивает ничего из этого — значит
        // и галочку ставить нечестно.
        if report.sameCountryAsHome {
            return CheckRow(symbol: "6.circle", title: "IPv6",
                            caption: "Выход в вашей стране — сравнивать не с чем", state: .unknown)
        }
        if let leak = report.ipv6Leak {
            return CheckRow(symbol: "6.circle.fill", title: "IPv6", caption: "Идёт мимо VPN: \(leak.ip)", state: .failed)
        }
        if let ipv6 = report.ipv6 {
            // Без адреса «до VPN» сравнивать нечего: зелёная галочка рисовала бы
            // домашний IPv6 как пропущенный через туннель.
            guard report.direct != nil else {
                return CheckRow(symbol: "6.circle", title: "IPv6",
                                caption: "Нечего сравнить: расширение не ответило", state: .unknown)
            }
            return CheckRow(symbol: "6.circle.fill", title: "IPv6", caption: "Через VPN: \(ipv6.ip)", state: .passed)
        }
        // No answer means the test didn't run — api-ipv6.ip.sb being down looks
        // the same as a network without IPv6 from here. Saying "утечки нет"
        // about a check that produced nothing is a false comfort on the one
        // screen whose job is to be honest about leaks.
        return CheckRow(symbol: "6.circle", title: "IPv6",
                        caption: "Не проверено: проба не ответила — IPv6-маршрута нет или api-ipv6.ip.sb недоступен",
                        state: .unknown)
    }

    private func dnsRow(_ report: LeakChecker.Report) -> some View {
        guard let servers = report.dns else {
            return CheckRow(symbol: "text.magnifyingglass", title: "DNS", caption: "Тест не ответил", state: .unknown)
        }
        let leaking = report.dnsLeak.count
        if leaking > 0 {
            return CheckRow(symbol: "text.magnifyingglass", title: "DNS",
                            caption: "\(leaking) \(WorldMap.plural(leaking, "сервер", "сервера", "серверов")) в вашей стране",
                            state: .failed)
        }
        let caption = servers.isEmpty ? "Запросы не дошли до теста" : "Запросы уходят через VPN"
        return CheckRow(symbol: "text.magnifyingglass", title: "DNS",
                        caption: report.sameCountryAsHome
                            ? "Выход в вашей стране — чьи это резолверы, непонятно"
                            : caption,
                        state: report.direct == nil || servers.isEmpty || report.sameCountryAsHome ? .unknown : .passed)
    }
}

/// One check: a glyph tile that fills with clay when it passed, the verdict
/// trailing.
private struct CheckRow: View {
    enum State {
        case passed, failed, unknown
    }

    let symbol: String
    let title: String
    let caption: String
    let state: State

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(state == .passed ? Color.white : Theme.inkSoft)
                .frame(width: 30, height: 30)
                .background(state == .passed ? AnyShapeStyle(Theme.accent.gradient) : AnyShapeStyle(Theme.idle),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .foregroundStyle(Theme.ink)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(state == .failed ? Theme.accent : Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: verdictSymbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(state == .failed ? Theme.accent : (state == .passed ? Theme.ink : Theme.inkSoft))
        }
        .accessibilityElement(children: .combine)
    }

    private var verdictSymbol: String {
        switch state {
        case .passed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

/// An address with where it is and whose it is.
private struct AddressRow: View {
    let info: LeakCheck.IPInfo

    var body: some View {
        HStack(spacing: 12) {
            FlagBadge(code: info.countryCode, size: 24)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.ip)
                    .font(.body.monospaced())
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !place.isEmpty {
                    Text(place)
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var place: String {
        let country = info.countryCode.map(Country.name) ?? info.country
        return [country, info.city, info.isp].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }
}

/// Resolvers of one operator in one country: big ones answer from a dozen
/// addresses, which say nothing more one by one.
private struct DNSGroup: Identifiable {
    var countryCode: String?
    var country: String?
    var org: String?
    var addresses: [String] = []
    var leaking = false

    var id: String { (countryCode ?? "") + "|" + (org ?? addresses.first ?? "") }

    static func of(_ servers: [LeakCheck.DNSServer], leaking: [LeakCheck.DNSServer]) -> [DNSGroup] {
        var groups: [DNSGroup] = []
        for server in servers {
            let index = groups.firstIndex { $0.countryCode == server.countryCode && $0.org == server.org && server.org != nil }
                ?? {
                    groups.append(DNSGroup(countryCode: server.countryCode, country: server.country, org: server.org))
                    return groups.count - 1
                }()
            groups[index].addresses.append(server.ip)
            if leaking.contains(server) { groups[index].leaking = true }
        }
        return groups
    }
}

private struct DNSGroupRow: View {
    let group: DNSGroup

    var body: some View {
        HStack(spacing: 12) {
            FlagBadge(code: group.countryCode, size: 20)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.org ?? group.addresses.first ?? "")
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(caption)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(group.leaking ? Theme.accent : Theme.inkSoft)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if group.leaking {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("В вашей стране")
            }
        }
        .padding(.vertical, 1)
    }

    private var caption: String {
        let country = group.countryCode.map(Country.name) ?? group.country
        var addresses = group.addresses.first ?? ""
        if group.addresses.count > 1 {
            addresses += " и ещё \(group.addresses.count - 1)"
        }
        // Without an operator the address is already the title.
        return [country, group.org == nil ? nil : addresses].compactMap { $0 }.joined(separator: " · ")
    }
}
