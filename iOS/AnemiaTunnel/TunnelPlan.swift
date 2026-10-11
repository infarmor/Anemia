import Foundation
import LoaderCore
import NetworkExtension
import os

/// Everything a start needs, worked out before the tunnel comes up: which
/// engine runs with what configuration, and the network settings iOS applies.
struct TunnelPlan {
    enum EngineConfig {
        case xray(json: String)
        case awg(uapi: String)
    }

    var engine: EngineConfig
    var settings: NEPacketTunnelNetworkSettings

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Xray's tun stack buffers one packet per MTU; 1500 keeps that small
    /// under the extension's memory limit.
    static let xrayMTU = 1500

    /// Runs before the tunnel exists, so the server's name still resolves on
    /// the physical network.
    static func make(_ setup: TunnelSetup, logFile: URL) throws -> TunnelPlan {
        let bypass = setup.splitTunnel?.activeEntries ?? []
        let adBlock = setup.adBlock ?? false
        if setup.server.proto.isWireGuardFamily {
            return try amneziaWG(setup.server, bypass: bypass, adBlock: adBlock)
        }
        return try xray(setup.server, masking: setup.masking, bypass: bypass, adBlock: adBlock, logFile: logFile)
    }

    /// Answers the bypassed names directly, the way the local network sees
    /// them (Yandex Public DNS): a Russian service resolved abroad may point
    /// at an edge that refuses Russian clients.
    static let bypassResolver = "77.88.8.8"

    // MARK: - Xray

    private static func xray(_ original: ProxyServer, masking: MaskingProfile,
                             bypass: [BypassEntry], adBlock: Bool, logFile: URL) throws -> TunnelPlan {
        var server = original
        let endpoint = try resolve(server.address)

        var builder = XrayConfigBuilder(apiPort: nil, bufferSizeKB: 4)
        builder.inboundMode = .packetTunnel(mtu: xrayMTU)
        builder.hysteriaMode = .native
        builder.collectsStats = true
        builder.dnsQueryStrategy = "UseIPv4"
        builder.logFile = logFile.path
        // The provider's own sockets skip the tunnel, so the engine sends
        // these straight to the physical network.
        builder.bypass = bypass
        builder.bypassResolver = bypassResolver
        if adBlock {
            builder.remoteDNS = AdBlockDNS.remoteDNS
            builder.dnsHosts[AdBlockDNS.dohHost] = AdBlockDNS.servers[0]
            // AdGuard answers from nearby nodes too, so bypassed names
            // still resolve locally — and lose their ads as well.
            builder.bypassResolver = AdBlockDNS.servers[0]
        }
        if endpoint != server.address {
            if server.proto.isHysteriaFamily {
                // Its dial would ask the system resolver, which by then asks
                // the tunnel: dial the address, keep the name for TLS.
                if server.sni?.isEmpty ?? true { server.sni = server.address }
                server.address = endpoint
            } else {
                // The builder routes the server's own lookup to this pin.
                builder.dnsHosts[server.address] = endpoint
            }
        }
        let json = try builder.makeConfigString(server: server, anti: masking.options)

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: endpoint)
        let ipv4 = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.252"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        // IPv6 goes into the tunnel as well: left out, it would bypass the VPN.
        let ipv6 = NEIPv6Settings(addresses: ["fdfe:dcba:9876::1"], networkPrefixLengths: [126])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6
        // Every :53 flow into the tunnel is answered by the engine, through
        // DoH over the proxy — the address itself doesn't matter.
        let dns = NEDNSSettings(servers: ["1.1.1.1"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        settings.mtu = NSNumber(value: xrayMTU)
        return TunnelPlan(engine: .xray(json: json), settings: settings)
    }

    // MARK: - AmneziaWG

    private static func amneziaWG(_ server: ProxyServer, bypass: [BypassEntry], adBlock: Bool) throws -> TunnelPlan {
        if let problem = AmneziaWGConfigBuilder.validate(server: server).first {
            throw Failure(message: "Конфиг AmneziaWG: \(problem)")
        }
        guard let profile = server.wgProfile else {
            throw Failure(message: "Конфиг AmneziaWG без ключа сервера")
        }
        let endpoint = try resolve(server.address)
        // The UAPI takes only an address literal as the endpoint.
        let uapi = try AmneziaWGConfigBuilder.makeUAPISetScript(server: server, endpointAddress: endpoint)

        // Both families the profile assigned, in whatever order it listed
        // them: the server accepts inner packets only from the addresses it
        // gave this peer, so a dual-stack conf has to configure both — taking
        // only the first IPv4 left IPv6 routed into a tunnel with no IPv6
        // address of its own.
        let interface = (server.userData?["wgAddress"] ?? "")
            .split(separator: ",")
            .compactMap { CIDR(String($0)) }
        var v4 = interface.filter { !$0.isIPv6 }
        var v6 = interface.filter(\.isIPv6)
        // A profile with no IPv4 of its own — IPv6-only, or a link that leaves
        // Address out — used to be refused on iOS while the Mac app connected
        // anyway from the default range. Same here: the server may refuse the
        // invented address, but a tunnel that comes up beats one that never
        // starts, and re-importing the full config fixes it properly.
        if v4.isEmpty, let fallback = CIDR("\(AmneziaWGConfigBuilder.fallbackTunAddress)/32") {
            v4 = [fallback]
        }
        let allowed = profile.allowedIPs.compactMap(CIDR.init)
        // A full tunnel without an IPv6 address would leak IPv6 around it.
        // A placeholder address routes it in; the server drops it, and apps
        // fall back to IPv4.
        if v6.isEmpty, allowed.contains(where: { $0.isIPv6 && $0.prefix == 0 }),
           let placeholder = CIDR("fd00:a3e1:a::2/128") {
            v6 = [placeholder]
        }

        // WireGuard routes by address only: bypassed domains are resolved now
        // and excluded by IP. (With the kill switch on, iOS ignores excluded
        // routes altogether.)
        let excluded = excludedRoutes(for: bypass)

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: endpoint)
        if !v4.isEmpty {
            let ipv4 = NEIPv4Settings(addresses: v4.map(\.address), subnetMasks: v4.map(\.ipv4Mask))
            ipv4.includedRoutes = allowed.filter { !$0.isIPv6 }.map {
                NEIPv4Route(destinationAddress: $0.network, subnetMask: $0.ipv4Mask)
            }
            // Только «мимо», и с потолком: исключённых маршрутов у iOS нет
            // никакого лимита на сторону безопасности — лишняя сотня просто
            // раздувает настройки, а два «/8» из чужого переноса уводят
            // почти весь интернет. Сброс маршрута ИЗ «included» утёк бы наружу,
            // поэтому их не урезаем никогда.
            ipv4.excludedRoutes = excluded.filter { !$0.isIPv6 }.prefix(128).map {
                NEIPv4Route(destinationAddress: $0.network, subnetMask: $0.ipv4Mask)
            }
            settings.ipv4Settings = ipv4
        }
        if !v6.isEmpty {
            let ipv6 = NEIPv6Settings(addresses: v6.map(\.address),
                                      networkPrefixLengths: v6.map { NSNumber(value: $0.prefix) })
            ipv6.includedRoutes = allowed.filter(\.isIPv6).map {
                NEIPv6Route(destinationAddress: $0.network, networkPrefixLength: NSNumber(value: $0.prefix))
            }
            ipv6.excludedRoutes = excluded.filter(\.isIPv6).prefix(128).map {
                NEIPv6Route(destinationAddress: $0.network, networkPrefixLength: NSNumber(value: $0.prefix))
            }
            settings.ipv6Settings = ipv6
        }
        // Строка `DNS =` в профиле — не только резолверы: wg-quick отдаёт
        // имена из неё как `search`, а не как `nameserver`, а `NEDNSSettings`
        // по заголовку SDK принимает адреса («an array of DNS server IP address
        // strings») и имя не отвергает — замерено: `NEDNSSettings(servers:
        // ["dns.google"]).servers` возвращает его обратно. То есть имя уехало бы
        // в настройки туннеля как адрес резолвера. На macOS такое отсекает
        // хелпер (`HelperService.setSystemDNS` отвечает «invalid resolver
        // address»), здесь такой страховки не было: остаются только адреса, а
        // когда их ни одного — публичный резолвер вместо мёртвого списка.
        let addresses = profile.resolverAddresses
        let resolvers = adBlock ? AdBlockDNS.servers : (addresses.isEmpty ? ["1.1.1.1"] : addresses)
        let dns = NEDNSSettings(servers: resolvers)
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        settings.mtu = NSNumber(value: profile.mtu ?? 1280)
        return TunnelPlan(engine: .awg(uapi: uapi), settings: settings)
    }

    // MARK: - Helpers

    /// Networks as they are; domains resolved to their current IPv4
    /// addresses. Names that don't resolve (a bare TLD like "ru") are skipped.
    ///
    /// iOS gives `startTunnel` only so long before it fails the connect, and
    /// a resolver that black-holes queries makes every lookup wait out its own
    /// timeout — so the list is dropped once the budget runs out. A missing
    /// excluded route only sends that one address through the VPN; a tunnel
    /// that never comes up sends everything nowhere.
    private static func excludedRoutes(for bypass: [BypassEntry], budget: TimeInterval = 4) -> [CIDR] {
        let deadline = Date().addingTimeInterval(budget)
        // Раздельно и в этом порядке: ниже список урезается до 128 маршрутов на
        // семейство, и резать надо хвост из разрешённых доменов (/32), а не
        // подсети, которые пользователь вписал сам (принтер, внутренняя сеть).
        var literal: [CIDR] = []
        var resolved: [CIDR] = []
        var lookups = 0
        for entry in bypass {
            switch entry {
            case .ipv4(let network), .ipv6(let network):
                if let cidr = CIDR(network) { literal.append(cidr) }
            case .domain(let name):
                guard lookups < 40, name.contains("."), Date() < deadline else { continue }
                lookups += 1
                resolved += ipv4(name, until: deadline).compactMap { CIDR("\($0)/32") }
            }
        }
        return literal + resolved
    }

    /// Addresses of `name`, given up on when `deadline` passes. Checking the
    /// clock between lookups isn't a budget by itself: `getaddrinfo` has no
    /// timeout of its own, so one black-holed name can cost half a minute on
    /// its own — and iOS counts that against the window it gives
    /// `startTunnel`. Losing a bypassed address sends one site through the
    /// VPN; missing that window leaves no tunnel at all.
    private static func ipv4(_ name: String, until deadline: Date) -> [String] {
        let found = OSAllocatedUnfairLock(initialState: [String]())
        let finished = DispatchSemaphore(value: 0)
        resolverQueue.async {
            found.withLock { $0 = DirectResolver.ipv4(name) }
            finished.signal()
        }
        let wait = min(2, deadline.timeIntervalSinceNow)
        guard wait > 0, finished.wait(timeout: .now() + wait) == .success else { return [] }
        return found.withLock { $0 }
    }

    private static let resolverQueue = DispatchQueue(label: "Anemia.resolver", qos: .utility, attributes: .concurrent)

    /// An address literal for `host`, IPv4 preferred.
    ///
    /// `getaddrinfo` сам не отдаёт время, и на сети, которая глушит DNS
    /// (отельная плёнка, перехват провайдера), один вызов стоит полминуты —
    /// ровно то окно, которое iOS даёт на `startTunnel` целиком. Тогда отказ
    /// приходил системным текстом, а три секунды, которые `startTunnel` держит
    /// под «Не удалось узнать адрес сервера», до своего ответа не доживали.
    ///
    /// Повторов ровно четыре, а не «до дедлайна»: `ipv4(_:until:)` не различает
    /// «не ответили» и «ответили, что записи нет», а отрицательный ответ
    /// кешируется — цикл по часам крутил бы `getaddrinfo` десятками тысяч раз
    /// внутри расширения. Четыре окна по две секунды дают те же 8 с живому, но
    /// медленному резолверу и не зависят от скачка системных часов.
    static func resolve(_ host: String, attempts: Int = 4) throws -> String {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if DirectResolver.isIPv4(bare) || CIDR(bare)?.isIPv6 == true { return bare }
        for _ in 0..<attempts {
            if let ip = ipv4(bare, until: Date().addingTimeInterval(2)).first { return ip }
        }
        throw Failure(message: "Не удалось узнать адрес сервера \(host)")
    }
}

/// An address with a prefix length, as WireGuard configs write them.
struct CIDR {
    let address: String
    let prefix: Int
    let isIPv6: Bool
    private let bytes: [UInt8]

    init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "/", maxSplits: 1)
        guard let head = parts.first else { return nil }
        let address = String(head)
        var raw = [UInt8](repeating: 0, count: 16)
        if inet_pton(AF_INET, address, &raw) == 1 {
            isIPv6 = false
            bytes = Array(raw.prefix(4))
        } else if inet_pton(AF_INET6, address, &raw) == 1 {
            isIPv6 = true
            bytes = raw
        } else {
            return nil
        }
        let maxPrefix = isIPv6 ? 128 : 32
        let prefix = parts.count == 2 ? Int(parts[1]) : maxPrefix
        guard let prefix, (0...maxPrefix).contains(prefix) else { return nil }
        self.address = address
        self.prefix = prefix
    }

    /// The address with its host bits cleared.
    var network: String {
        var masked = bytes
        for i in masked.indices {
            let keep = min(max(prefix - i * 8, 0), 8)
            masked[i] &= UInt8(truncatingIfNeeded: 0xFF << (8 - keep))
        }
        return Self.format(masked, ipv6: isIPv6)
    }

    /// Dotted-quad netmask (IPv4 only).
    var ipv4Mask: String {
        let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
        return (0..<4).map { String((mask >> (24 - 8 * $0)) & 0xFF) }.joined(separator: ".")
    }

    private static func format(_ bytes: [UInt8], ipv6: Bool) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        var raw = bytes
        _ = inet_ntop(ipv6 ? AF_INET6 : AF_INET, &raw, &buffer, socklen_t(buffer.count))
        return String(cString: buffer)
    }
}
