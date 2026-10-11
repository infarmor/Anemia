import LoaderCore

extension ProxyServer {
    /// "VLESS · XHTTP · Reality", "Hysteria 2", "AmneziaWG 2.0"…
    var kindLabel: String {
        switch proto {
        case .vless: "VLESS" + streamLabel
        case .vmess: "VMess" + streamLabel
        case .trojan: "Trojan" + streamLabel
        case .shadowsocks: "Shadowsocks"
        case .hysteria2: "Hysteria 2"
        case .hysteria: "Hysteria 1"
        case .amnezia: "AmneziaWG \(awgVersion.rawValue)"
        case .wireguard: "WireGuard"
        }
    }

    /// The iOS engine has no Hysteria 1 client.
    var runsOnIOS: Bool { proto != .hysteria }

    /// What tells servers of one list apart, for tight spots like the Live
    /// Activity: "XHTTP · Reality" rather than "VLESS · XHTTP · Reality".
    var shortKindLabel: String {
        switch proto {
        case .vless:
            let stream = streamLabel
            return stream.isEmpty ? "VLESS" : String(stream.dropFirst(3))
        default:
            return kindLabel
        }
    }

    private var streamLabel: String {
        var parts: [String] = []
        switch network {
        case .tcp: break
        case .ws: parts.append("WS")
        case .grpc: parts.append("gRPC")
        case .http: parts.append("HTTP/2")
        case .httpupgrade: parts.append("HTTPUpgrade")
        case .quic: parts.append("QUIC")
        case .kcp: parts.append("mKCP")
        case .xhttp: parts.append("XHTTP")
        }
        switch security {
        case .reality: parts.append("Reality")
        case .tls, .xtls: parts.append("TLS")
        case .none: break
        }
        return parts.map { " · " + $0 }.joined()
    }
}

extension MaskingProfile {
    var russianTitle: String {
        switch self {
        case .off: "Выключена"
        case .balanced: "Обычная"
        case .maximum: "Максимальная"
        case .ruYandex: "Под Яндекс"
        case .ruVK: "Под VK"
        }
    }

    var russianSubtitle: String {
        switch self {
        case .off: "Без обфускации — быстрее всего."
        case .balanced: "Фрагментация и мусорные пакеты — рекомендуется."
        case .maximum: "Мелкая фрагментация и больше мусора — надёжнее, но медленнее."
        case .ruYandex: "Трафик похож на Яндекс: фрагментация, мусор и подставной SNI."
        case .ruVK: "Трафик похож на VK: фрагментация, мусор и подставной SNI."
        }
    }
}

extension SplitTunnelParser.Rejection {
    /// The parser is shared with the Mac app and explains itself in English.
    var russianReason: String {
        if reason.hasPrefix("too broad") {
            // "too broad — /4 would send most traffic around the VPN (use /8 or narrower)"
            let prefixes = reason.matches(of: #/\/(\d+)/#).map { "/\($0.output.1)" }
            let family = reason.contains("IPv6") ? "IPv6-трафика" : "трафика"
            let limit = prefixes.count > 1 ? " Нужно \(prefixes[1]) или уже." : ""
            return "Слишком широкая сеть: мимо VPN пошла бы большая часть \(family).\(limit)"
        }
        switch reason {
        case "not a valid IPv4 address": return "Неверный IPv4-адрес"
        case "not a valid IPv6 address": return "Неверный IPv6-адрес"
        case "prefix length must be 0–32": return "Длина префикса — от 0 до 32"
        case "prefix length must be 0–128": return "Длина префикса — от 0 до 128"
        case "loopback never goes through the VPN": return "Адреса самого устройства и так не идут через VPN"
        case "that range is the VPN tunnel itself": return "Это адреса самого туннеля"
        case "empty domain": return "Пустой домен"
        case "not a valid domain": return "Неверный домен"
        case "domain is too long": return "Слишком длинный домен"
        case "not a valid IP address or domain": return "Не похоже ни на IP-адрес, ни на домен"
        default: return reason
        }
    }
}
