import Foundation
import LoaderCore
import Observation
import os

/// "Проверка утечек": the address sites see and the resolvers answering
/// this device's lookups, compared with the address the provider gave —
/// which the tunnel extension measures, its sockets going around the tunnel.
@MainActor
@Observable
final class LeakChecker {
    struct Report {
        var date = Date()
        /// Тот же момент по часам, которые идут и во сне: `DispatchTime` стоит,
        /// пока телефон спит, и вчерашний отчёт переживал ночь как «свежий».
        /// `date` при этом остаётся для показа.
        var takenAt = ContinuousClock.now
        /// The server the check went through; nil with the VPN off.
        var serverID: UUID?
        /// What sites see.
        var exit: LeakCheck.IPInfo?
        /// The provider's own address. With the VPN off it's `exit`.
        var direct: LeakCheck.IPInfo?
        /// Nil: IPv6 doesn't get out at all.
        var ipv6: LeakCheck.IPInfo?
        /// Nil when the DNS test didn't answer.
        var dns: [LeakCheck.DNSServer]?
        var findings: [LeakCheck.Finding] = []

        enum Verdict: Equatable {
            /// Nothing to hide behind: the VPN is off.
            case unprotected
            /// The address check itself failed.
            case failed
            /// The tunnel works; without the provider's address there's
            /// nothing to compare with.
            case unknown
            case leaks
            case clean
            /// The address is hidden, but a probe never answered — which is
            /// not the same as "nothing leaked".
            case incomplete
        }

        var verdict: Verdict {
            guard exit != nil else { return .failed }
            guard serverID != nil else { return .unprotected }
            if !findings.isEmpty { return .leaks }
            guard direct != nil else { return .unknown }
            // Выход в той же стране, что и провайдер: `LeakCheck.findings`
            // сознательно перестаёт сравнивать DNS и IPv6 (страна ничего не
            // доказывает), и без этой строки экран показывал бы зелёные галочки
            // там, где сравнения вовсе не было.
            if sameCountryAsHome { return .unknown }
            // Без ответа осталась любая проба, а не только DNS: строка списка
            // уже читает «Не проверено» для молчавшего IPv6, и заголовок «Утечек
            // нет» противоречил бы ей на том самом экране, который обязан
            // честно говорить, чего он не видел. Пустой список резолверов —
            // то же самое: тест ответил, но ничего не увидел (`dnsRow` и так
            // рисует «Запросы не дошли до теста»).
            return (dnsMissing || ipv6 == nil) ? .incomplete : .clean
        }

        /// Ни ответа, ни результата: DNS-проба не состоялась.
        private var dnsMissing: Bool { dns == nil || dns?.isEmpty == true }

        /// Адрес выхода и адрес провайдера — из одной страны.
        var sameCountryAsHome: Bool {
            guard let exit = exit?.countryCode?.uppercased(),
                  let home = direct?.countryCode?.uppercased() else { return false }
            return exit == home
        }

        /// The tests that produced no answer, named the way the screen names
        /// their rows.
        var missing: [String] {
            var names: [String] = []
            if dnsMissing { names.append("DNS") }
            if ipv6 == nil { names.append("IPv6") }
            return names
        }

        var bypassed: Bool { findings.contains(.tunnelBypassed) }

        var ipv6Leak: LeakCheck.IPInfo? {
            for case .ipv6Leak(let info) in findings { return info }
            return nil
        }

        var dnsLeak: [LeakCheck.DNSServer] {
            for case .dnsLeak(let servers) in findings { return servers }
            return []
        }
    }

    private(set) var report: Report?
    /// What the running check is doing; nil when idle.
    private(set) var step: String?

    var isRunning: Bool { step != nil }

    @ObservationIgnored private let tunnel: TunnelController

    init(tunnel: TunnelController) {
        self.tunnel = tunnel
    }

    /// The last report still describes the connection: same server, same
    /// VPN state, not too old.
    /// Туннель, через который проба вообще что-то доказывает: `.connected` и
    /// `.reasserting` (туннель существует, при kill switch наружу не уходит),
    /// но НЕ `.connecting` — до `setTunnelNetworkSettings` маршруты ещё не
    /// установлены, проба уходит домой, и экран называл бы это «адрес скрыт».
    private var viaTunnel: Bool {
        tunnel.status == .connected || tunnel.status == .reasserting
    }

    var isCurrent: Bool {
        guard let report else { return false }
        let server = viaTunnel ? tunnel.activeServerID : nil
        // `nil == nil` тоже совпадение: отчёт, снятый без выбранного сервера,
        // оставался «актуальным» при живом туннеле с нерасшифрованным
        // конфигурационным профилем, и экран не перепроверял себя полчаса.
        guard let server, report.serverID == server else { return false }
        // Возраст — по часам, которые идут и во сне: шаг стенных назад делал
        // любой отчёт «вечным», а пауза сна — нестарящейся.
        return ContinuousClock.now - report.takenAt < .seconds(30 * 60)
    }

    func run() async {
        guard step == nil else { return }
        step = "Узнаю адрес…"
        defer { step = nil }
        // `.connected` или `.reasserting`: на переподключении туннель
        // существует, и с kill switch наружу ничего не уходит, а прежнее
        // «статус == connected» записывало такой замер как «VPN выключен —
        // сайты видят ваш настоящий адрес». Если байты и пошли мимо, это
        // ловится ниже: `findings` вернёт `.tunnelBypassed`. В `.connecting`
        // проба уходит домой до установки маршрутов — её нечем сравнивать.
        let viaVPN = viaTunnel
        var fresh = Report(serverID: viaVPN ? tunnel.activeServerID : nil)
        // A fresh session: connections kept alive from before the VPN came
        // up would still go around it.
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        async let exit = try? LeakCheck.publicAddress(session: session)
        async let ipv6 = try? LeakCheck.publicAddress(ipv6: true, session: session)
        var direct: LeakCheck.IPInfo?
        if viaVPN {
            direct = await tunnel.directAddress()
        }
        fresh.exit = await exit
        fresh.ipv6 = await ipv6
        fresh.direct = viaVPN ? direct : fresh.exit

        step = "Проверяю DNS…"
        fresh.dns = try? await LeakCheck.dnsServers(session: session) { name in await Self.lookUp(name) }
        if viaVPN {
            fresh.findings = LeakCheck.findings(exit: fresh.exit, direct: fresh.direct,
                                                ipv6: fresh.ipv6, dns: fresh.dns ?? [])
        }
        // Выйти со экрана = отменить `.task`: отменённая URLSession отвечает
        // отказом на обеих пробах, и иначе оборванная проверка ложится поверх
        // настоящей с тем же `serverID` и свежей датой — то есть выглядит
        // актуальной, и при возврате на экран она уже не перезапустится.
        guard !Task.isCancelled else { return }
        fresh.date = Date()
        fresh.takenAt = ContinuousClock.now
        report = fresh
    }

    /// Looks `name` up through the system resolver, the way any app here
    /// would — giving up after a few seconds.
    nonisolated private static func lookUp(_ name: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable () -> Void = {
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume() }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                var result: UnsafeMutablePointer<addrinfo>?
                if getaddrinfo(name, nil, nil, &result) == 0, let result {
                    freeaddrinfo(result)
                }
                finish()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish() }
        }
    }
}
