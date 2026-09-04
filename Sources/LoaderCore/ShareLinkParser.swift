import Foundation

/// Parses proxy share links into the canonical ``ProxyServer`` model.
///
/// Supported schemes: `vless://`, `vmess://`, `ss://`, `trojan://`.
/// The parser is deliberately lenient about missing/optional query fields so
/// that real-world links from a range of panels import cleanly.
public enum ShareLinkParser {

    /// Parse a single share link. Whitespace is trimmed first.
    public static func parse(_ raw: String) throws -> ProxyServer {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { throw ParseError.emptyInput }

        guard let schemeRange = link.range(of: "://") else {
            throw ParseError.malformedURI(link)
        }
        let scheme = String(link[link.startIndex..<schemeRange.lowerBound]).lowercased()

        switch scheme {
        case "vless":   return try parseVLESS(link)
        case "trojan":  return try parseTrojan(link)
        case "vmess":   return try parseVMess(link)
        case "ss":      return try parseShadowsocks(link)
        default:        throw ParseError.unsupportedScheme(scheme)
        }
    }

    // MARK: - VLESS

    private static func parseVLESS(_ link: String) throws -> ProxyServer {
        let uri = try URIParts(link)
        guard let uuid = uri.userInfo, !uuid.isEmpty else { throw ParseError.missingField("uuid") }
        guard let host = uri.host, let port = uri.port else { throw ParseError.missingField("host/port") }

        let q = uri.query
        let security = StreamSecurity(rawValue: q["security"] ?? "none") ?? .none
        var server = ProxyServer(
            name: uri.fragment ?? host,
            proto: .vless,
            address: host,
            port: port,
            credential: uuid,
            network: NetworkType(rawValue: q["type"] ?? "tcp") ?? .tcp,
            security: security,
            flow: q["flow"].flatMap { $0.isEmpty ? nil : $0 }
        )
        applyStreamParams(&server, query: q)
        return server
    }

    // MARK: - Trojan

    private static func parseTrojan(_ link: String) throws -> ProxyServer {
        let uri = try URIParts(link)
        guard let password = uri.userInfo, !password.isEmpty else { throw ParseError.missingField("password") }
        guard let host = uri.host, let port = uri.port else { throw ParseError.missingField("host/port") }

        let q = uri.query
        // Trojan defaults to TLS even when `security` is omitted.
        let security = StreamSecurity(rawValue: q["security"] ?? "tls") ?? .tls
        var server = ProxyServer(
            name: uri.fragment ?? host,
            proto: .trojan,
            address: host,
            port: port,
            credential: password,
            network: NetworkType(rawValue: q["type"] ?? "tcp") ?? .tcp,
            security: security,
            flow: q["flow"].flatMap { $0.isEmpty ? nil : $0 }
        )
        applyStreamParams(&server, query: q)
        return server
    }

    // MARK: - VMess

    private static func parseVMess(_ link: String) throws -> ProxyServer {
        let body = String(link.dropFirst("vmess://".count))
        guard let data = Base64.decodeFlexible(body),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.invalidBase64
        }

        func str(_ key: String) -> String? {
            if let s = obj[key] as? String { return s }
            if let n = obj[key] as? NSNumber { return n.stringValue }
            return nil
        }
        func intVal(_ key: String) -> Int? {
            if let n = obj[key] as? NSNumber { return n.intValue }
            if let s = obj[key] as? String { return Int(s) }
            return nil
        }

        guard let add = str("add"), let port = intVal("port"), let id = str("id") else {
            throw ParseError.missingField("add/port/id")
        }

        let tls = (str("tls") ?? "").lowercased()
        let security: StreamSecurity = tls == "tls" ? .tls : (tls == "reality" ? .reality : .none)
        let net = NetworkType(rawValue: str("net") ?? "tcp") ?? .tcp

        var server = ProxyServer(
            name: str("ps") ?? add,
            proto: .vmess,
            address: add,
            port: port,
            credential: id,
            alterId: intVal("aid") ?? 0,
            network: net,
            security: security,
            sni: str("sni").flatMap { $0.isEmpty ? nil : $0 },
            fingerprint: str("fp").flatMap { $0.isEmpty ? nil : $0 },
            realityPublicKey: str("pbk").flatMap { $0.isEmpty ? nil : $0 },
            realityShortId: str("sid").flatMap { $0.isEmpty ? nil : $0 },
            realitySpiderX: str("spx").flatMap { $0.isEmpty ? nil : $0 },
            path: str("path").flatMap { $0.isEmpty ? nil : $0 },
            host: str("host").flatMap { $0.isEmpty ? nil : $0 },
            headerType: str("type").flatMap { $0.isEmpty ? nil : $0 }
        )
        if let alpn = str("alpn"), !alpn.isEmpty {
            server.alpn = alpn.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        return server
    }

    // MARK: - Shadowsocks

    private static func parseShadowsocks(_ link: String) throws -> ProxyServer {
        // Two encodings exist:
        //   Legacy:  ss://base64(method:password@host:port)#name
        //   SIP002:  ss://base64(method:password)@host:port/?plugin=...#name
        var body = String(link.dropFirst("ss://".count))

        // Peel off #name first.
        var name: String?
        if let hash = body.firstIndex(of: "#") {
            name = String(body[body.index(after: hash)...]).removingPercentEncoding
            body = String(body[body.startIndex..<hash])
        }

        // If there's an '@', it's SIP002 (userinfo may be base64 or plain).
        if body.contains("@") {
            // Strip any ?plugin=... query for v1 (SS plugins handled later).
            var authority = body
            if let qMark = body.firstIndex(of: "?") {
                authority = String(body[body.startIndex..<qMark])
            }
            guard let at = authority.lastIndex(of: "@") else { throw ParseError.malformedURI(link) }
            let userInfoRaw = String(authority[authority.startIndex..<at])
            let hostPort = String(authority[authority.index(after: at)...])

            let userInfo: String
            if let decoded = Base64.decodeFlexible(userInfoRaw).flatMap({ String(data: $0, encoding: .utf8) }),
               decoded.contains(":") {
                userInfo = decoded
            } else {
                userInfo = userInfoRaw.removingPercentEncoding ?? userInfoRaw
            }
            let (method, password) = try splitMethodPassword(userInfo, link: link)
            let (host, port) = try splitHostPort(hostPort, link: link)
            return ProxyServer(
                name: name ?? host, proto: .shadowsocks, address: host, port: port,
                credential: password, method: method
            )
        } else {
            // Legacy: whole thing is base64(method:password@host:port)
            guard let decoded = Base64.decodeFlexible(body).flatMap({ String(data: $0, encoding: .utf8) }) else {
                throw ParseError.invalidBase64
            }
            guard let at = decoded.lastIndex(of: "@") else { throw ParseError.malformedURI(link) }
            let userInfo = String(decoded[decoded.startIndex..<at])
            let hostPort = String(decoded[decoded.index(after: at)...])
            let (method, password) = try splitMethodPassword(userInfo, link: link)
            let (host, port) = try splitHostPort(hostPort, link: link)
            return ProxyServer(
                name: name ?? host, proto: .shadowsocks, address: host, port: port,
                credential: password, method: method
            )
        }
    }

    // MARK: - Shared stream-parameter application (VLESS/Trojan)

    private static func applyStreamParams(_ server: inout ProxyServer, query q: [String: String]) {
        server.sni = q["sni"].flatMap { $0.isEmpty ? nil : $0 } ?? q["peer"]
        server.fingerprint = q["fp"].flatMap { $0.isEmpty ? nil : $0 }
        server.realityPublicKey = q["pbk"].flatMap { $0.isEmpty ? nil : $0 }
        server.realityShortId = q["sid"].flatMap { $0.isEmpty ? nil : $0 }
        server.realitySpiderX = q["spx"].flatMap { $0.isEmpty ? nil : $0 }
        server.allowInsecure = (q["allowInsecure"] == "1" || q["allowInsecure"]?.lowercased() == "true")
        server.headerType = q["headerType"].flatMap { $0.isEmpty ? nil : $0 }
        if let alpn = q["alpn"], !alpn.isEmpty {
            server.alpn = alpn.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        // gRPC uses serviceName; ws/http use path + Host header.
        if server.network == .grpc {
            server.path = q["serviceName"] ?? q["path"]
        } else {
            server.path = q["path"].flatMap { $0.isEmpty ? nil : $0 }
            server.host = q["host"].flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    // MARK: - Small helpers

    private static func splitMethodPassword(_ s: String, link: String) throws -> (String, String) {
        guard let colon = s.firstIndex(of: ":") else { throw ParseError.malformedURI(link) }
        return (String(s[s.startIndex..<colon]), String(s[s.index(after: colon)...]))
    }

    private static func splitHostPort(_ s: String, link: String) throws -> (String, Int) {
        // IPv6 in brackets: [::1]:443
        if s.hasPrefix("[") , let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()) else {
                throw ParseError.malformedURI(link)
            }
            return (host, port)
        }
        guard let colon = s.lastIndex(of: ":"), let port = Int(s[s.index(after: colon)...]) else {
            throw ParseError.malformedURI(link)
        }
        return (String(s[s.startIndex..<colon]), port)
    }
}

/// Decomposed URI parts for `scheme://userInfo@host:port?query#fragment` links.
private struct URIParts {
    let userInfo: String?
    let host: String?
    let port: Int?
    let query: [String: String]
    let fragment: String?

    init(_ link: String) throws {
        guard let schemeRange = link.range(of: "://") else { throw ParseError.malformedURI(link) }
        var rest = String(link[schemeRange.upperBound...])

        // Fragment (#name), percent-decoded.
        var frag: String?
        if let hash = rest.firstIndex(of: "#") {
            frag = String(rest[rest.index(after: hash)...]).removingPercentEncoding
            rest = String(rest[rest.startIndex..<hash])
        }
        self.fragment = frag

        // Query string.
        var queryDict: [String: String] = [:]
        if let qMark = rest.firstIndex(of: "?") {
            let qStr = String(rest[rest.index(after: qMark)...])
            rest = String(rest[rest.startIndex..<qMark])
            for pair in qStr.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(kv[0])
                let value = kv.count > 1 ? String(kv[1]) : ""
                queryDict[key] = value.removingPercentEncoding ?? value
            }
        }
        self.query = queryDict

        // Authority: userInfo@host:port
        var authority = rest
        var user: String?
        if let at = authority.lastIndex(of: "@") {
            user = String(authority[authority.startIndex..<at]).removingPercentEncoding
            authority = String(authority[authority.index(after: at)...])
        }
        self.userInfo = user

        // host:port with IPv6 bracket support.
        if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
            self.host = String(authority[authority.index(after: authority.startIndex)..<close])
            let tail = authority[authority.index(after: close)...]
            self.port = tail.hasPrefix(":") ? Int(tail.dropFirst()) : nil
        } else if let colon = authority.lastIndex(of: ":") {
            self.host = String(authority[authority.startIndex..<colon])
            self.port = Int(authority[authority.index(after: colon)...])
        } else {
            self.host = authority.isEmpty ? nil : authority
            self.port = nil
        }
    }
}
