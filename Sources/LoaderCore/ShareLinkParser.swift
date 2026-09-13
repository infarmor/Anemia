import Foundation
import Compression

/// Parses proxy share links into the canonical ``ProxyServer`` model.
///
/// Supported schemes: `vless://`, `vmess://`, `ss://`, `trojan://`, plus the
/// WireGuard family — `amnezia://`, `awg://` (base64 of a wg-quick `.conf`,
/// the Amnezia app's export format) and `wireguard://`, `wg://`
/// (query-parameter links, v2rayN/Hiddify style) — the Hysteria family
/// (`hysteria2://`, `hy2://`, and `hysteria://` for protocol v1) and the
/// Amnezia config container `vpn://`. Raw `[Interface]`/`[Peer]` conf text is
/// accepted too, via ``parseConfigText(_:)``. The parser is deliberately
/// lenient about missing/optional query fields so that real-world links from
/// a range of panels import cleanly.
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
        case "amnezia", "awg":
            return try parseAWGLink(link, scheme: scheme, proto: .amnezia)
        case "wireguard", "wg":
            return try parseAWGLink(link, scheme: scheme, proto: .wireguard)
        case "hysteria":
            return try parseHysteria(link, version: 1)
        case "hysteria2", "hy2":
            return try parseHysteria(link, version: 2)
        case "vpn":
            return try parseVPNLink(link)
        default:        throw ParseError.unsupportedScheme(scheme)
        }
    }

    // MARK: - Hysteria

    /// Two schemes, two protocol generations:
    ///   * `hysteria2://auth@host:port?sni=…&obfs=salamander&obfs-password=…` —
    ///     Hysteria 2 (also spelled `hy2://`);
    ///   * `hysteria://host:port?auth=…&peer=…&upmbps=…&downmbps=…&obfs=xplus`
    ///     — Hysteria 1, kept for import so a subscription still shows the
    ///     server (the engine path rejects protocol v1 with a clear error
    ///     rather than silently importing an unusable server).
    private static func parseHysteria(_ link: String, version: Int) throws -> ProxyServer {
        let parts = try URIParts(link)
        guard let host = parts.host, !host.isEmpty else {
            throw ParseError.malformedURI(link)
        }
        let port = parts.port ?? (version == 2 ? 443 : 80)
        try validatePort(port, link: link)
        let q = parts.query
        // Query keys arrive in their original case (obfsParam, UpMbps…), so
        // match case-insensitively — panels mix spellings freely.
        let lq = Dictionary(uniqueKeysWithValues: q.map { ($0.key.lowercased(), $0.value) })
        // Hysteria 2 carries the password in the userinfo; hysteria 1 puts it
        // in the query. Tolerate either spot for both (panels are sloppy).
        let auth = parts.userInfo ?? lq["auth"]
        guard let auth, !auth.isEmpty else {
            throw ParseError.missingField(version == 2 ? "auth (userinfo password)" : "auth query")
        }
        let name = parts.fragment ?? host
        var extras: [String: String] = ["hysteriaVersion": String(version)]
        if version == 2 {
            // Hysteria 2: auth in userinfo, everything else in the query.
            for (k, v) in lq {
                switch k {
                case "obfs":            extras["obfs"] = v
                case "obfs-password":   extras["obfsPassword"] = v
                case "obfsparam":       extras["obfsPassword"] = v
                case "pinsha256":       extras["pinSHA256"] = v
                case "mport", "ports":  extras["portHopping"] = v
                default: break
                }
            }
            return ProxyServer(
                name: name, proto: .hysteria2, address: host, port: port,
                credential: auth,
                security: .tls,
                sni: lq["sni"] ?? lq["peer"],
                allowInsecure: boolParam(lq["insecure"]),
                userData: extras)
        }
        // Hysteria 1: auth/peer/bandwidth/obfs all live in the query.
        if let obfsParam = lq["obfsparam"] ?? lq["obfs-param"] { extras["obfsPassword"] = obfsParam }
        if let obfs = lq["obfs"] { extras["obfs"] = obfs }
        if let up = lq["upmbps"] ?? lq["up"] { extras["upmbps"] = up }
        if let down = lq["downmbps"] ?? lq["down"] { extras["downmbps"] = down }
        if let proto = lq["protocol"] { extras["protocol"] = proto }
        let alpn: [String] = (lq["alpn"] ?? "").isEmpty ? [] : lq["alpn"]!.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return ProxyServer(
            name: name, proto: .hysteria, address: host, port: port,
            credential: auth,
            security: .tls,
            sni: lq["peer"] ?? lq["sni"],
            alpn: alpn,
            allowInsecure: boolParam(lq["insecure"]),
            userData: extras)
    }

    /// Truthy spellings seen in the wild: `1`, `true`, `yes` (everything else
    /// counts as false — links never use these flags for "please validate").
    private static func boolParam(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return ["1", "true", "yes"].contains(raw.lowercased())
    }

    // MARK: - Amnezia vpn:// container

    /// The Amnezia app's config-share format: `vpn://` + base64url (unpadded)
    /// of either a Qt `qCompress` blob (4-byte big-endian uncompressed-length
    /// header, then a zlib stream) or, uncompressed fallback, plain base64 of
    /// the JSON itself. The JSON is an envelope:
    ///
    ///     { hostName, description, defaultContainer, dns1, dns2,
    ///       containers: [ { container: "amnezia-awg",
    ///                       awg: { last_config: "<json string>", port, ... } } ] }
    ///
    /// `last_config` is itself a JSON string (double serialization) whose
    /// `config` field carries the verbatim wg-quick INI — which is exactly
    /// what ``parseConfigText`` already knows how to eat. The structured
    /// fields (client_priv_key, Jc/H*, …) back-fill the INI if it's missing.
    private static func parseVPNLink(_ link: String) throws -> ProxyServer {
        var payload = link
        if let schemeEnd = payload.range(of: "://") {
            payload = String(payload[schemeEnd.upperBound...])
        }
        payload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { throw ParseError.malformedURI(link) }
        // A trailing fragment (#Name) is decoration some generators add.
        if let hash = payload.firstIndex(of: "#") {
            payload = String(payload[payload.startIndex..<hash])
        }
        guard var data = Base64.decodeFlexible(payload) else {
            throw ParseError.invalidBase64
        }

        // qUncompress, done by hand: Apple's Compression framework speaks raw
        // DEFLATE, so peel the 4-byte length header and the 2-byte zlib
        // wrapper (CMF 0x78 + FLG, FCHECK makes CMF<<8|FLG % 31 == 0), inflate
        // the rest and ignore the 4-byte Adler-32 tail. Only attempt this when
        // the header actually looks like qCompress — otherwise the payload is
        // plain JSON bytes (Amnezia also exports uncompressed).
        if data.count > 6, data[4] == 0x78,
           (UInt16(data[4]) << 8 | UInt16(data[5])) % 31 == 0 {
            // The header names the exact uncompressed size — size the output
            // buffer from it (bounded, a config is never huge) so a truncated
            // inflate can't pass unnoticed.
            let expected = (Int(data[0]) << 24) | (Int(data[1]) << 16)
                | (Int(data[2]) << 8) | Int(data[3])
            if expected > 0, expected <= 16_000_000,
               let inflated = inflateRaw(Array(data.dropFirst(6)), expectedBytes: expected),
               inflated.count == expected {
                data = Data(inflated)
            }
        }

        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ParseError.malformedURI("vpn link: not an Amnezia config (undecodable JSON)")
        }
        return try serverFromAmneziaEnvelope(obj, link: link)
    }

    /// Walk the Amnezia envelope and produce a server. The WireGuard family
    /// goes through ``parseConfigText`` (verbatim INI), Xray containers hand
    /// their last_config to the ordinary link parser; anything else throws.
    private static func serverFromAmneziaEnvelope(_ env: [String: Any], link: String) throws -> ProxyServer {
        let containers = (env["containers"] as? [[String: Any]]) ?? []
        let wanted = env["defaultContainer"] as? String
        // Prefer the container defaultContainer names; else the first
        // protocol-shaped one in document order.
        let ordered = wanted.flatMap { id in containers.first { ($0["container"] as? String) == id } }.map { [$0] } ?? []
        let container = ordered.first ?? containers.first

        func lastConfigString(_ obj: [String: Any]) -> String? {
            switch obj["last_config"] {
            case let s as String: return s
            case let d as [String: Any]:
                return (try? JSONSerialization.data(withJSONObject: d)).flatMap { String(data: $0, encoding: .utf8) }
            default: return nil
            }
        }

        if let container {
            let kind = (container["container"] as? String)?.lowercased() ?? ""
            for key in ["awg", "wireguard"] {
                guard let cfg = container[key] as? [String: Any], !kind.contains("xray") else { continue }
                var ini = lastConfigString(cfg).flatMap { iniFromLastConfig($0) }
                // Older exports store the INI directly under the container.
                if ini == nil, let direct = container["config"] as? String, direct.contains("[Interface]") {
                    ini = direct
                }
                guard var conf = ini else {
                    throw ParseError.malformedURI("vpn link: WireGuard container without a usable config")
                }
                // The envelope is authoritative for DNS when the INI is silent.
                let dns = [env["dns1"] as? String, env["dns2"] as? String]
                    .compactMap { $0 }.filter { !$0.isEmpty }
                if !dns.isEmpty, !conf.lowercased().contains("dns") {
                    conf += "\nDNS = \(dns.joined(separator: ", "))"
                }
                let server = try parseConfigText(conf, proto: kind.contains("awg") ? .amnezia : .wireguard)
                // Prefer the envelope's human label over the file's absence of one.
                if let desc = env["description"] as? String, !desc.isEmpty {
                    var named = server
                    named.name = desc
                    return named
                }
                return server
            }
            if kind.contains("xray") {
                for key in ["xray", "vless"] {
                    if let cfg = container[key] as? [String: Any],
                       let inner = lastConfigString(cfg) {
                        let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.lowercased().contains("://") {
                            return try parse(trimmed)
                        }
                        // A raw JSON xray config: fish the vless link out of it.
                        if let data = trimmed.data(using: .utf8),
                           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                            for v in obj.values {
                                if let s = v as? String, s.lowercased().hasPrefix("vless://") {
                                    return try parse(s)
                                }
                            }
                        }
                    }
                }
                throw ParseError.unsupportedScheme("vpn link: xray container without a vless link")
            }
        }

        // No containers at all: the JSON itself may already be a last_config
        // (some generators skip the envelope). Try to read it as one.
        if let ini = iniFromLastConfig((try? JSONSerialization.data(withJSONObject: env)).flatMap { String(data: $0, encoding: .utf8) } ?? "") {
            return try parseConfigText(ini, proto: .amnezia)
        }
        throw ParseError.unsupportedScheme("vpn link: no supported container (amnezia-awg / wireguard / xray)")
    }

    /// Pull the wg-quick INI out of a `last_config` value: it may already BE
    /// the INI, or it may be a JSON object whose `config` field holds the
    /// INI. JSON is tried FIRST: the double-serialized form still *contains*
    /// the literal `[Interface]` (it's inside a JSON string), so an
    /// order-blind "contains [Interface]" check used to hand the whole JSON
    /// blob to the INI parser, which then failed on "missing PrivateKey".
    private static func iniFromLastConfig(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let conf = obj["config"] as? String,
           conf.lowercased().contains("[interface]") {
            return conf
        }
        return trimmed.lowercased().contains("[interface]") ? trimmed : nil
    }

    /// Raw-DEFLATE inflate (Apple Compression framework), with the 4-byte
    /// Adler-32 trailer simply left unread: the decoder stops at the final
    /// block, trailing bytes are never consumed.
    private static func inflateRaw(_ bytes: [UInt8], expectedBytes: Int) -> [UInt8]? {
        var dst = [UInt8](repeating: 0, count: expectedBytes)
        let written = dst.withUnsafeMutableBytes { dstPtr -> Int in
            bytes.withUnsafeBufferPointer { srcPtr in
                compression_decode_buffer(
                    dstPtr.baseAddress!, expectedBytes,
                    srcPtr.baseAddress!, srcPtr.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        return written > 0 ? Array(dst.prefix(written)) : nil
    }

    // MARK: - AmneziaWG / WireGuard

    /// Two encodings exist in the wild:
    ///   * `amnezia://BASE64` — base64 of a whole wg-quick conf (the Amnezia
    ///     app's export; `awg://` likewise), and
    ///   * `wireguard://privkey@host:port?publickey=…&junkPacketCount=…` —
    ///     the query-parameter form panels emit (Hiddify/v2rayN naming).
    /// The base64 alphabet never contains "://", so the two are told apart by
    /// the presence of an `@host` authority or a leading `?`.
    private static func parseAWGLink(_ link: String, scheme: String, proto: ProxyProtocol) throws -> ProxyServer {
        var body = String(link.dropFirst(scheme.count + 3))
        var name: String?
        if let hash = body.firstIndex(of: "#") {
            name = String(body[body.index(after: hash)...]).removingPercentEncoding
            body = String(body[body.startIndex..<hash])
        }
        let hasAuthority = body.range(of: "^[^/?#]+@", options: .regularExpression) != nil
        // The query form always carries "?" (publickey=…); base64 never does —
        // and never carries "@" either, so a bare base64 blob of a conf can't
        // be mistaken for `privkey@host:port` here. (A regex on the leading
        // run matched *any* slash-free base64 and misrouted it to the query
        // parser.)
        let looksLikeQuery = body.hasPrefix("?") || body.contains("?")
        if hasAuthority || looksLikeQuery, !body.contains("[Interface]") {
            return try parseAWGQueryLink(body, proto: proto, name: name, link: link)
        }
        // Base64 of a whole conf (possibly percent-wrapped by the exporter).
        let unescaped = body.removingPercentEncoding ?? body
        guard let decoded = Base64.decodeFlexible(body)
            .flatMap({ String(data: $0, encoding: .utf8) })
            ?? Base64.decodeFlexible(unescaped).flatMap({ String(data: $0, encoding: .utf8) }),
            decoded.contains("[Interface]") || decoded.contains("[Peer]") else {
            throw ParseError.malformedURI(link)
        }
        var server = try parseConfigText(decoded, proto: proto)
        if let name, !name.isEmpty { server.name = name }
        return server
    }

    /// `wireguard://` / `wg://` with query parameters. Accepts both the
    /// lowercase UAPI-ish names (`publickey`, `allowedips`, `junkpacketcount`)
    /// and v2rayN's CamelCase aliases (`junkPacketCount`, `initPacketJunkSize`,
    /// `magicHeader1`…), case-insensitively — real links mix them freely.
    private static func parseAWGQueryLink(_ body: String, proto: ProxyProtocol,
                                          name: String?, link: String) throws -> ProxyServer {
        var rest = body
        if rest.hasPrefix("?") { rest = String(rest.dropFirst()) }
        // Split off the authority: everything before the first "?" (or all of
        // it) is `privkey@host:port`.
        var authority = rest
        var queryRaw = ""
        if let q = authority.firstIndex(of: "?") {
            queryRaw = String(authority[authority.index(after: q)...])
            authority = String(authority[authority.startIndex..<q])
        }
        var q: [String: String] = [:]
        for pair in queryRaw.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let k = kv.first else { continue }
            let v = kv.count > 1 ? String(kv[1]) : ""
            q[String(k).lowercased()] = v.removingPercentEncoding ?? v
        }

        var privateKey = ""
        var host = "", port = 0
        if let at = authority.lastIndex(of: "@") {
            let userRaw = String(authority[authority.startIndex..<at])
            if let decoded = Base64.decodeFlexible(userRaw),
               decoded.count == 32,
               let key = String(data: decoded, encoding: .utf8), key.count == 44 {
                // Doubly-encoded userinfo (base64 of the 44-char base64 key).
                privateKey = key
            } else {
                privateKey = userRaw.removingPercentEncoding ?? userRaw
            }
            authority = String(authority[authority.index(after: at)...])
        }
        if privateKey.isEmpty { privateKey = q["privatekey"] ?? "" }
        guard !privateKey.isEmpty else { throw ParseError.missingField("private key") }
        if let colon = authority.lastIndex(of: ":"),
           let p = Int(authority[authority.index(after: colon)...]), (1...65535).contains(p) {
            var h = String(authority[authority.startIndex..<colon])
            // IPv6 literals arrive bracketed in authority position; strip the
            // brackets the same way URIParts does — a stored "[2001:db8::1]"
            // fails the helper's getaddrinfo at connect.
            if h.hasPrefix("["), h.hasSuffix("]"), h.count > 2 { h = String(h.dropFirst().dropLast()) }
            host = h
            port = p
        }
        guard !host.isEmpty, port > 0 else { throw ParseError.missingField("host/port") }

        let profile = WireGuardProfile(
            peerPublicKey: q["publickey"] ?? "",
            presharedKey: q["presharedkey"].flatMap { $0.isEmpty ? nil : $0 },
            allowedIPs: (q["allowedips"] ?? "0.0.0.0/0, ::/0")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            dns: (q["dns"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            mtu: q["mtu"].flatMap(Int.init),
            keepAlive: q["keepalive"].flatMap(Int.init) ?? q["persistentkeepaliveinterval"].flatMap(Int.init)
        )
        var server = ProxyServer(
            name: name ?? host, proto: proto, address: host, port: port,
            credential: privateKey, awg: obfuscationFromQuery(q), wgProfile: profile
        )
        if proto == .amnezia, server.awg == nil {
            // An amnezia:// query link with no obfuscation parameters at all
            // would be indistinguishable from plain WireGuard — keep the AWG
            // label but let the engine run the unobfuscated handshake.
            server.awg = AWGObfuscation()
        }
        return server
    }

    /// Query-param → obfuscation mapping. Lowercased keys, with the v2rayN
    /// aliases folded onto the UAPI names.
    private static func obfuscationFromQuery(_ q: [String: String]) -> AWGObfuscation? {
        func i(_ key: String) -> Int? { q[key].flatMap { $0.isEmpty ? nil : Int($0) } }
        func s(_ key: String) -> String? { q[key].flatMap { $0.isEmpty ? nil : $0 } }
        var o = AWGObfuscation()
        o.junkPackets = i("jc") ?? i("junkpacketcount")
        o.junkMin = i("jmin") ?? i("junkpacketminsize")
        o.junkMax = i("jmax") ?? i("junkpacketmaxsize")
        o.initPadding = i("s1") ?? i("initpacketjunksize")
        o.responsePadding = i("s2") ?? i("responsepacketjunksize")
        o.cookiePadding = i("s3") ?? i("cookiepacketjunksize")
        o.transportPadding = i("s4") ?? i("transportpacketjunksize")
        o.header1 = s("h1") ?? s("magicheader1")
        o.header2 = s("h2") ?? s("magicheader2")
        o.header3 = s("h3") ?? s("magicheader3")
        o.header4 = s("h4") ?? s("magicheader4")
        o.headerProtectionKey = s("headerprotectionkey")
        o.contentPaddingAddition = i("contentpaddingaddition")
        o.randomTrailers = q["randomtrailers"].map { $0 == "1" || $0.lowercased() == "true" }
        o.disableCookies = q["disablecookies"].map { $0 == "1" || $0.lowercased() == "true" }
        let hasAny = o.junkPackets != nil || o.junkMin != nil || o.junkMax != nil
            || o.initPadding != nil || o.responsePadding != nil || o.cookiePadding != nil
            || o.transportPadding != nil || o.header1 != nil || o.header2 != nil
            || o.header3 != nil || o.header4 != nil || o.headerProtectionKey != nil
            || o.contentPaddingAddition != nil || o.randomTrailers != nil || o.disableCookies != nil
        return hasAny ? o : nil
    }

    /// Parse a wg-quick style `[Interface]`/`[Peer]` conf — the interchange
    /// format of the Amnezia app, wg-quick itself and every panel's export.
    /// Keys are matched case-insensitively; the obfuscation keys accept both
    /// the wiki's CamelCase (`Jc`, `H1`) and the UAPI's lowercase (`jc`, `h1`)
    /// spellings, plus v2rayN's verbose aliases, so any generator's output
    /// imports. `proto` selects the saved protocol flavor (defaults to
    /// AmneziaWG — the common case for obfuscated configs).
    public static func parseConfigText(_ raw: String, proto: ProxyProtocol = .amnezia) throws -> ProxyServer {
        // A UTF-8 BOM (the norm for .conf files exported on Windows, or
        // pasted from editors that emit one) is not in .whitespacesAndNewlines
        // — left in place it made the first "[Interface]" line miss the
        // section-header check, silently voiding the whole section and
        // failing with a misleading "missing PrivateKey" about a key that is
        // right there.
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        guard lower.contains("[interface]") || lower.contains("[peer]") else {
            throw ParseError.awgConfig("not a WireGuard config (no [Interface]/[Peer] section)")
        }
        var section = ""
        var interface: [String: String] = [:]
        var peer: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("[") {
                section = l.lowercased()
                continue
            }
            guard !section.isEmpty, let eq = l.firstIndex(of: "=") else { continue }
            let key = String(l[l.startIndex..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(l[l.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch section {
            case "[interface]": interface[key] = value
            case "[peer]": peer[key] = value
            default: break
            }
        }
        guard let privateKey = interface["privatekey"], !privateKey.isEmpty else {
            throw ParseError.awgConfig("missing PrivateKey")
        }
        guard let publicKey = peer["publickey"], !publicKey.isEmpty else {
            throw ParseError.awgConfig("missing peer PublicKey")
        }
        guard let endpoint = peer["endpoint"], !endpoint.isEmpty else {
            throw ParseError.awgConfig("missing Endpoint in [Peer]")
        }
        var endpointParts = endpoint
        if let slash = endpoint.firstIndex(of: "/") {
            endpointParts = String(endpoint[endpoint.startIndex..<slash])
        }
        guard let colon = endpointParts.lastIndex(of: ":"),
              let port = Int(endpointParts[endpointParts.index(after: colon)...]),
              (1...65535).contains(port) else {
            throw ParseError.awgConfig("Endpoint must be host:port — got \(endpoint)")
        }
        let host = host(fromEndpoint: endpointParts)

        func intKey(_ keys: String...) -> Int? {
            for k in keys { if let v = interface[k], let i = Int(v) { return i } }
            return nil
        }
        func strKey(_ keys: String...) -> String? {
            for k in keys { if let v = interface[k], !v.isEmpty { return v } }
            return nil
        }
        var o = AWGObfuscation()
        o.junkPackets = intKey("jc", "junkpacketcount")
        o.junkMin = intKey("jmin", "junkpacketminsize")
        o.junkMax = intKey("jmax", "junkpacketmaxsize")
        o.initPadding = intKey("s1", "initpacketjunksize")
        o.responsePadding = intKey("s2", "responsepacketjunksize")
        o.cookiePadding = intKey("s3", "cookiepacketjunksize")
        o.transportPadding = intKey("s4", "transportpacketjunksize")
        o.header1 = strKey("h1", "magicheader1")
        o.header2 = strKey("h2", "magicheader2")
        o.header3 = strKey("h3", "magicheader3")
        o.header4 = strKey("h4", "magicheader4")
        o.specialHandshakes = (1...5).compactMap { interface["i\($0)"] }
        o.headerProtectionKey = strKey("headerprotectionkey")
        o.contentPaddingAddition = intKey("contentpaddingaddition")
        o.randomTrailers = interface["randomtrailers"].map { $0 == "1" || $0.lowercased() == "true" }
        o.disableCookies = interface["disablecookies"].map { $0 == "1" || $0.lowercased() == "true" }
        // The FULL field set, mirroring obfuscationFromQuery — the earlier
        // subset (Jc/H1/S1/I*/HPK only) downgraded a 2.x/3.x conf whose only
        // obfuscation keys were, say, ContentPaddingAddition or
        // RandomTrailers to plain WireGuard AND dropped the parameters
        // entirely, so the server's handshake failed with no diagnostic.
        let hasObfuscation = o.junkPackets != nil || o.junkMin != nil || o.junkMax != nil
            || o.initPadding != nil || o.responsePadding != nil || o.cookiePadding != nil
            || o.transportPadding != nil || o.header1 != nil || o.header2 != nil
            || o.header3 != nil || o.header4 != nil || o.headerProtectionKey != nil
            || o.contentPaddingAddition != nil || o.randomTrailers != nil
            || o.disableCookies != nil || !o.specialHandshakes.isEmpty
        // A conf without any obfuscation keys parsed as amnezia:// is plain
        // WireGuard in disguise — save the honest protocol so the engine
        // choice (and the UI badge) matches reality.
        let actualProto: ProxyProtocol = (proto == .amnezia && !hasObfuscation) ? .wireguard : proto

        var profile = WireGuardProfile(peerPublicKey: publicKey)
        profile.presharedKey = peer["presharedkey"].flatMap { $0.isEmpty ? nil : $0 }
        if let ips = peer["allowedips"], !ips.isEmpty {
            profile.allowedIPs = ips.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let dns = interface["dns"], !dns.isEmpty {
            profile.dns = dns.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        profile.mtu = intKey("mtu")
        profile.keepAlive = peer["persistentkeepalive"].flatMap(Int.init)
            ?? peer["persistentkeepaliveinterval"].flatMap(Int.init)

        // Tunnel address: the conf's own Address (first IPv4 with its
        // prefixlen) is authoritative when present — the server routes
        // accordingly. Falls back to the app's default range at bring-up.
        var wgAddress: String? = nil
        if let addr = interface["address"], !addr.isEmpty {
            for part in addr.split(separator: ",") {
                let p = part.trimmingCharacters(in: .whitespaces)
                if let slash = p.firstIndex(of: "/"),
                   DirectResolver.isIPv4(String(p[p.startIndex..<slash])) {
                    wgAddress = p
                    break
                }
                if DirectResolver.isIPv4(p) {
                    wgAddress = p + "/32"
                    break
                }
            }
        }

        var server = ProxyServer(
            name: host, proto: actualProto,
            address: host, port: port,
            credential: privateKey,
            awg: actualProto == .amnezia ? o : (hasObfuscation ? o : nil),
            wgProfile: profile
        )
        server.userData = ["wgAddress": wgAddress ?? ""]
        return server
    }

    private static func host(fromEndpoint endpoint: String) -> String {
        var e = endpoint
        if e.hasPrefix("["), let close = e.firstIndex(of: "]") {
            return String(e[e.index(after: e.startIndex)..<close])
        }
        if let colon = e.lastIndex(of: ":") { return String(e[e.startIndex..<colon]) }
        return e
    }

    // MARK: - VLESS

    private static func parseVLESS(_ link: String) throws -> ProxyServer {
        let uri = try URIParts(link)
        guard let uuid = uri.userInfo, !uuid.isEmpty else { throw ParseError.missingField("uuid") }
        guard let host = uri.host, let port = uri.port else { throw ParseError.missingField("host/port") }
        try validatePort(port, link: link)

        let q = uri.query
        let security = securityValue(q["security"], fallback: .none)
        var server = ProxyServer(
            name: uri.fragment ?? host,
            proto: .vless,
            address: host,
            port: port,
            credential: uuid,
            network: try networkType(q["type"]),
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
        try validatePort(port, link: link)

        let q = uri.query
        // Trojan defaults to TLS even when `security` is omitted.
        let security = securityValue(q["security"], fallback: .tls)
        var server = ProxyServer(
            name: uri.fragment ?? host,
            proto: .trojan,
            address: host,
            port: port,
            credential: password,
            network: try networkType(q["type"]),
            security: security
            // No `flow`: the XTLS flow field exists only for VLESS — a
            // trojan link's stray `flow=` param (panels emit it gratuitously)
            // would reach the trojan outbound where Xray rejects unknown
            // flow values at config validation.
        )
        applyStreamParams(&server, query: q)
        return server
    }

    /// Case-insensitive `security=` parsing: real-world links carry `TLS`,
    /// `Reality`, `REALITY`… A case-sensitive rawValue lookup silently fell
    /// back to `.none` — a TLS server parsed as plaintext that could never
    /// handshake, with no diagnostic.
    private static func securityValue(_ raw: String?, fallback: StreamSecurity) -> StreamSecurity {
        guard let raw, !raw.isEmpty else { return fallback }
        return StreamSecurity(rawValue: raw.lowercased()) ?? fallback
    }

    /// Ports outside 1…65535 parse fine as integers but reach the engine
    /// config verbatim, where the outbound bind fails at start with an opaque
    /// error — reject at the source instead.
    private static func validatePort(_ port: Int, link: String) throws {
        guard (1...65535).contains(port) else { throw ParseError.malformedURI(link) }
    }

    // MARK: - VMess

    private static func parseVMess(_ link: String) throws -> ProxyServer {
        // Some generators append a `#remarks` fragment (or a query) to the
        // base64 body: `vmess://BASE64#name`. The base64 alphabet never
        // contains '#' or '?', so anything from the first one is decoration —
        // but decodeFlexible ignores unknown characters, so ASCII letters of
        // a fragment name would be swallowed into the payload, shift the
        // stream alignment and corrupt the JSON (verified: `"port":"443,"id"`
        // — a quote eaten, JSONSerialization throws, the whole link dies as
        // invalidBase64). Peel it first, exactly like the ss branch does.
        var body = String(link.dropFirst("vmess://".count))
        if let cut = body.firstIndex(where: { $0 == "#" || $0 == "?" }) {
            body = String(body[body.startIndex..<cut])
        }
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

        guard let add = str("add"), !add.isEmpty,
              let port = intVal("port"), (1...65535).contains(port),
              let id = str("id"), !id.isEmpty else {
            throw ParseError.missingField("add/port/id")
        }

        // Panels emit `tls` three ways: string ("tls"/"reality"/"xtls"/
        // "none"), JSON boolean (`"tls": true` — NSNumber.stringValue would
        // turn it into "1" and fall through to `.none`), or absent. Boolean
        // must be checked before `str`, or `true` masquerades as "1".
        let tlsName: String
        if let b = obj["tls"] as? Bool {
            tlsName = b ? "tls" : "none"
        } else {
            tlsName = (str("tls") ?? "none").lowercased()
        }
        let security: StreamSecurity
        switch tlsName {
        case "tls":     security = .tls
        case "reality": security = .reality
        case "xtls":    security = .xtls
        default:        security = .none
        }
        let net = try networkType(str("net"))

        var server = ProxyServer(
            name: str("ps") ?? add,
            proto: .vmess,
            address: add,
            port: port,
            credential: id,
            alterId: intVal("aid") ?? 0,
            network: net,
            security: security,
            vmessCipher: str("scy").flatMap { $0.isEmpty ? nil : $0 },
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
        // `mode=multi` for a gRPC transport never reaches the stream-params
        // path (the vmess JSON carries it as a top-level field, not a query):
        // without this, multi-mode servers failed their handshake silently.
        if net == .grpc, let mode = str("mode") {
            server.grpcMultiMode = (mode.lowercased() == "multi")
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

        // Peel off the query and keep it: both encodings can carry parameters
        // (panels append them to legacy links too, where a leftover `?…` tail
        // would shift the base64 decode), and the SIP002 branch checks it for
        // a load-bearing plugin.
        var query: String?
        if let qMark = body.firstIndex(of: "?") {
            query = String(body[body.index(after: qMark)...])
            body = String(body[body.startIndex..<qMark])
        }

        // If there's an '@', it's SIP002 (userinfo may be base64 or plain).
        if body.contains("@") {
            var authority = body
            if let qStr = query {
                // A SIP003 `plugin` (obfs-local, v2ray-plugin, shadow-tls…)
                // is load-bearing obfuscation: ProxyServer has no field for
                // it, and importing the link as plain Shadowsocks would look
                // healthy, then fail every handshake server-side with no
                // explanation. Fail the parse loudly instead, so the
                // subscription importer reports the real reason.
                for pair in qStr.split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard kv[0] == "plugin" else { continue }
                    let raw = kv.count > 1 ? String(kv[1]) : ""
                    let plugin = raw.removingPercentEncoding ?? raw
                    if !plugin.isEmpty {
                        let name = plugin.split(separator: ";").first.map(String.init) ?? plugin
                        throw ParseError.unsupportedTransport("plugin: \(name)")
                    }
                }
            }
            guard let at = authority.lastIndex(of: "@") else { throw ParseError.malformedURI(link) }
            let userInfoRaw = String(authority[authority.startIndex..<at])
            let hostPort = String(authority[authority.index(after: at)...])

            let userInfo: String
            if let decoded = Base64.decodeFlexible(userInfoRaw).flatMap({ String(data: $0, encoding: .utf8) }),
               decoded.contains(":") {
                userInfo = decoded
            } else {
                // SIP002 generators commonly percent-encode the base64
                // userinfo itself (`…d29yZA%3D%3D` — `=` padded as %3D,
                // `+`/`/` as %2B/%2F). The first decode above sees the raw,
                // still-encoded string and fails, so percent-decode FIRST
                // and retry the base64 before falling back to treating it
                // as plain `method:password`.
                let unescaped = userInfoRaw.removingPercentEncoding ?? userInfoRaw
                if let retried = Base64.decodeFlexible(unescaped).flatMap({ String(data: $0, encoding: .utf8) }),
                   retried.contains(":") {
                    userInfo = retried
                } else {
                    userInfo = unescaped
                }
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

    /// Normalize a link's transport name (VLESS/Trojan `type`, VMess `net`).
    ///
    /// Real-world links use several aliases for the same transports (`h2` for
    /// HTTP/2, `kcp` for mKCP, `raw`/`websocket` for the long names) and some
    /// transports the bundled engine no longer ships (`xhttp`/`splithttp`).
    /// A silent `.tcp` fallback here used to rewire such links into a plain
    /// TCP connection that could never handshake — unknown transports now fail
    /// the parse loudly, so the subscription importer reports the server as
    /// broken instead of connecting nonsense.
    private static func networkType(_ raw: String?) throws -> NetworkType {
        let name = (raw ?? "tcp").lowercased()
        switch name {
        case "", "tcp", "raw", "none":    return .tcp
        case "ws", "websocket":           return .ws
        case "grpc":                      return .grpc
        case "http", "h2":                return .http
        case "httpupgrade":               return .httpupgrade
        case "quic":                      return .quic
        case "kcp", "mkcp":               return .kcp
        default:                          throw ParseError.unsupportedTransport(name)
        }
    }

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
        // gRPC carries serviceName in `path`, the `:authority` header in `host`
        // and its multiplexing mode in `mode`; ws/http use path + Host header.
        // An *empty* serviceName must be dropped, not preferred: some panels
        // emit `serviceName=` as a placeholder next to a real `path=`, and
        // Xray cannot dial gRPC without a service name.
        if server.network == .grpc {
            server.path = q["serviceName"].flatMap { $0.isEmpty ? nil : $0 }
                ?? q["path"].flatMap { $0.isEmpty ? nil : $0 }
            server.host = q["host"].flatMap { $0.isEmpty ? nil : $0 }
            server.grpcMultiMode = (q["mode"]?.lowercased() == "multi")
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
        // SIP002 allows (and panels love) a trailing path after the port —
        // `ss://b64@host:8388/?plugin=…` or even a bare `/`. The query is
        // already peeled, so anything from the first `/` onward is transport
        // decoration, not part of the authority. IPv6 literals never contain
        // a slash, so this cut is unambiguous.
        var s = s
        if let slash = s.firstIndex(of: "/") {
            s = String(s[s.startIndex..<slash])
        }
        // IPv6 in brackets: [::1]:443
        if s.hasPrefix("[") , let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()), (1...65535).contains(port) else {
                throw ParseError.malformedURI(link)
            }
            return (host, port)
        }
        guard let colon = s.lastIndex(of: ":"),
              let port = Int(s[s.index(after: colon)...]),
              (1...65535).contains(port),
              // Reject an unbracketed IPv6 literal masquerading as
              // host:port — `2001:db8::1` would split into host "2001:db8:"
              // port 1 and dial nothing. Real hosts never contain a colon.
              !s[s.startIndex..<colon].contains(":") else {
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

        // Fragment (#name), percent-decoded. A bare `#` yields no name —
        // an empty string would surface as a blank label in the UI instead
        // of falling back to the host.
        var frag: String?
        if let hash = rest.firstIndex(of: "#") {
            frag = String(rest[rest.index(after: hash)...]).removingPercentEncoding
            rest = String(rest[rest.startIndex..<hash])
        }
        self.fragment = (frag?.isEmpty == false) ? frag : nil

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

        // host:port with IPv6 bracket support. A port outside 1…65535 parses
        // fine as an integer but fails the engine's outbound bind at connect
        // time with an opaque error — reject it here, at the source.
        func portValue(_ s: String) -> Int? {
            guard let p = Int(s), (1...65535).contains(p) else { return nil }
            return p
        }
        if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
            self.host = String(authority[authority.index(after: authority.startIndex)..<close])
            let tail = authority[authority.index(after: close)...]
            self.port = tail.hasPrefix(":") ? portValue(String(tail.dropFirst())) : nil
        } else if let colon = authority.lastIndex(of: ":") {
            // Only treat the last colon as a port separator when the tail
            // really is a port and the head cannot be an unbracketed IPv6
            // literal. `vless://u@2001:db8::1` (no brackets, no port) used to
            // parse as address "2001:db8:" port 1 — a server that dials
            // nothing instead of failing at import.
            let portPart = String(authority[authority.index(after: colon)...])
            let hostPart = String(authority[authority.startIndex..<colon])
            if portPart.allSatisfy(\.isNumber), !hostPart.contains(":") {
                self.host = hostPart
                self.port = portValue(portPart)
            } else {
                self.host = authority.isEmpty ? nil : authority
                self.port = nil
            }
        } else {
            self.host = authority.isEmpty ? nil : authority
            self.port = nil
        }
    }
}
