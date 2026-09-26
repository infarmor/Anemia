import Foundation
import Network

/// AmneziaWG protocol generations. Each version strictly extends the previous
/// one's obfuscation set; the engine on the other end must be at least as new
/// as the version a config names, or its UAPI parser rejects the keys.
///
///   1.0  junk packets (Jc/Jmin/Jmax) + handshake padding (S1/S2) + fixed
///        magic headers H1–H4
///   1.5  + CPS special-handshake chain I1–I5 (client-side only)
///   2.0  + cookie/transport padding S3/S4; H1–H4 became random *ranges*
///   3.0  + header protection (ChaCha20 over header fields) and
///        ContentPaddingAddition; randomized protocol timers
///   3.1  + RandomTrailers (pad to MTU), DisableCookies
public enum AWGVersion: String, Codable, Sendable, CaseIterable {
    case v1 = "1.0"
    case v15 = "1.5"
    case v2 = "2.0"
    case v3 = "3.0"
    case v31 = "3.1"

    /// Highest generation whose marker parameters are present in an
    /// obfuscation set. A config that only ever sets S1/S2/H1–H4 declares
    /// itself 1.0 even though a 3.1 engine happily accepts it — the version
    /// describes what the config *uses*, not what the engine supports.
    public static func detect(from o: AWGObfuscation?) -> AWGVersion {
        guard let o else { return .v1 }
        if o.randomTrailers == true || o.disableCookies == true { return .v31 }
        if o.headerProtectionKey != nil || o.contentPaddingAddition != nil || o.hasTimingOverrides { return .v3 }
        if o.cookiePadding != nil || o.transportPadding != nil
            || [o.header1, o.header2, o.header3, o.header4].contains(where: { $0?.contains("-") == true }) {
            return .v2
        }
        if !o.specialHandshakes.isEmpty { return .v15 }
        return .v1
    }
}

/// The AmneziaWG obfuscation parameter set, exactly as a server config (or a
/// share link) carries it. Every field is optional: plain WireGuard servers
/// carry none of these, and older saved state predates the whole struct.
///
/// Values that the protocol allows to be ranges (H1–H4 from 2.0) stay strings
/// — `"1234567"` or `"1234567-1234599"` — so a range survives a round trip
/// without inventing a range type everywhere.
public struct AWGObfuscation: Codable, Sendable, Equatable {
    /// Jc — junk packets sent before every handshake (client-side only).
    public var junkPackets: Int?
    /// Jmin — junk packet minimum size.
    public var junkMin: Int?
    /// Jmax — junk packet maximum size (must stay below the link MTU).
    public var junkMax: Int?
    /// S1 — random bytes prepended to the handshake initiation.
    public var initPadding: Int?
    /// S2 — random bytes prepended to the handshake response.
    public var responsePadding: Int?
    /// S3 — cookie-reply padding (2.0+).
    public var cookiePadding: Int?
    /// S4 — transport packet padding (2.0+, ≤32; ≥12 with header protection).
    public var transportPadding: Int?
    /// H1–H4 — WireGuard's predictable packet-type bytes replaced by a value
    /// or a random range. Must match the server and must not overlap.
    public var header1: String?
    public var header2: String?
    public var header3: String?
    public var header4: String?
    /// I1–I5 — pre-handshake packets mimicking another protocol (1.5+),
    /// client-side only. Hex payloads with `<b hex>`/`<t>`/`<r N>` tags.
    public var specialHandshakes: [String]
    /// ChaCha20 key encrypting low-entropy header fields (3.0+).
    public var headerProtectionKey: String?
    /// Random extra padding inside encrypted payloads, bytes — a value or a
    /// range (3.0+).
    public var contentPaddingAddition: String?
    /// Protocol timer overrides (3.0+), each a value or a random range —
    /// seconds, attempts for the last. Randomized timers take away the fixed
    /// rekey/keepalive rhythm a classifier can lock onto.
    public var rekeyAfterTime: String?
    public var rekeyTimeout: String?
    public var rejectAfterTime: String?
    public var keepaliveTimeout: String?
    public var maxHandshakeAttempts: String?
    /// Random bytes appended to packets (3.1+). Both ends must agree: a peer
    /// without it doesn't recognize the lengthened handshake.
    public var randomTrailers: Bool?
    /// Disable cookiereply responses (3.1+).
    public var disableCookies: Bool?

    public var hasTimingOverrides: Bool {
        [rekeyAfterTime, rekeyTimeout, rejectAfterTime, keepaliveTimeout, maxHandshakeAttempts]
            .contains { $0 != nil }
    }

    /// No obfuscation parameter at all — plain WireGuard on the wire.
    public var isEmpty: Bool { self == AWGObfuscation() }

    public init(
        junkPackets: Int? = nil, junkMin: Int? = nil, junkMax: Int? = nil,
        initPadding: Int? = nil, responsePadding: Int? = nil,
        cookiePadding: Int? = nil, transportPadding: Int? = nil,
        header1: String? = nil, header2: String? = nil,
        header3: String? = nil, header4: String? = nil,
        specialHandshakes: [String] = [],
        headerProtectionKey: String? = nil,
        contentPaddingAddition: String? = nil,
        rekeyAfterTime: String? = nil, rekeyTimeout: String? = nil,
        rejectAfterTime: String? = nil, keepaliveTimeout: String? = nil,
        maxHandshakeAttempts: String? = nil,
        randomTrailers: Bool? = nil, disableCookies: Bool? = nil
    ) {
        self.junkPackets = junkPackets
        self.junkMin = junkMin
        self.junkMax = junkMax
        self.initPadding = initPadding
        self.responsePadding = responsePadding
        self.cookiePadding = cookiePadding
        self.transportPadding = transportPadding
        self.header1 = header1
        self.header2 = header2
        self.header3 = header3
        self.header4 = header4
        self.specialHandshakes = specialHandshakes
        self.headerProtectionKey = headerProtectionKey
        self.contentPaddingAddition = contentPaddingAddition
        self.rekeyAfterTime = rekeyAfterTime
        self.rekeyTimeout = rekeyTimeout
        self.rejectAfterTime = rejectAfterTime
        self.keepaliveTimeout = keepaliveTimeout
        self.maxHandshakeAttempts = maxHandshakeAttempts
        self.randomTrailers = randomTrailers
        self.disableCookies = disableCookies
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        junkPackets = try c.decodeIfPresent(Int.self, forKey: .junkPackets)
        junkMin = try c.decodeIfPresent(Int.self, forKey: .junkMin)
        junkMax = try c.decodeIfPresent(Int.self, forKey: .junkMax)
        initPadding = try c.decodeIfPresent(Int.self, forKey: .initPadding)
        responsePadding = try c.decodeIfPresent(Int.self, forKey: .responsePadding)
        cookiePadding = try c.decodeIfPresent(Int.self, forKey: .cookiePadding)
        transportPadding = try c.decodeIfPresent(Int.self, forKey: .transportPadding)
        header1 = try c.decodeIfPresent(String.self, forKey: .header1)
        header2 = try c.decodeIfPresent(String.self, forKey: .header2)
        header3 = try c.decodeIfPresent(String.self, forKey: .header3)
        header4 = try c.decodeIfPresent(String.self, forKey: .header4)
        specialHandshakes = try c.decodeIfPresent([String].self, forKey: .specialHandshakes) ?? []
        headerProtectionKey = try c.decodeIfPresent(String.self, forKey: .headerProtectionKey)
        // Saved before 3.x ranges were modeled, this was a plain integer —
        // a strict String decode would drop every saved AmneziaWG server.
        if let legacy = try? c.decodeIfPresent(Int.self, forKey: .contentPaddingAddition) {
            contentPaddingAddition = String(legacy)
        } else {
            contentPaddingAddition = try c.decodeIfPresent(String.self, forKey: .contentPaddingAddition)
        }
        rekeyAfterTime = try c.decodeIfPresent(String.self, forKey: .rekeyAfterTime)
        rekeyTimeout = try c.decodeIfPresent(String.self, forKey: .rekeyTimeout)
        rejectAfterTime = try c.decodeIfPresent(String.self, forKey: .rejectAfterTime)
        keepaliveTimeout = try c.decodeIfPresent(String.self, forKey: .keepaliveTimeout)
        maxHandshakeAttempts = try c.decodeIfPresent(String.self, forKey: .maxHandshakeAttempts)
        randomTrailers = try c.decodeIfPresent(Bool.self, forKey: .randomTrailers)
        disableCookies = try c.decodeIfPresent(Bool.self, forKey: .disableCookies)
    }
}

/// WireGuard peer/profile values shared by AmneziaWG and plain WireGuard
/// servers. The client private key lives in ``ProxyServer/credential`` (so
/// identityKey rotates with key rotation, as with every other protocol's
/// credential); everything that describes the *peer side* lives here.
public struct WireGuardProfile: Codable, Sendable, Equatable {
    /// Peer (server) public key, base64.
    public var peerPublicKey: String
    /// Optional pre-shared key, base64.
    public var presharedKey: String?
    /// Routes to pull into the tunnel. Defaults to the full tunnel.
    public var allowedIPs: [String]
    /// Resolvers to hand the system while tunneled (may be empty).
    public var dns: [String]
    public var mtu: Int?
    public var keepAlive: Int?

    public init(
        peerPublicKey: String,
        presharedKey: String? = nil,
        allowedIPs: [String] = ["0.0.0.0/0", "::/0"],
        dns: [String] = [],
        mtu: Int? = nil,
        keepAlive: Int? = nil
    ) {
        self.peerPublicKey = peerPublicKey
        self.presharedKey = presharedKey
        self.allowedIPs = allowedIPs
        self.dns = dns
        self.mtu = mtu
        self.keepAlive = keepAlive
    }
}

// MARK: - ProxyServer WireGuard fields

extension ProxyServer {
    /// AmneziaWG protocol generation this server's obfuscation set exercises.
    public var awgVersion: AWGVersion { AWGVersion.detect(from: awg) }
}

// MARK: - Errors

extension ParseError {
    /// A WireGuard-family config is structurally unusable — e.g. a missing
    /// private or peer key. Distinct from `missingField` so the UI can point
    /// at the conf file rather than a share link.
    public static func awgConfig(_ reason: String) -> ParseError {
        .malformedURI("AmneziaWG config: \(reason)")
    }
}

// MARK: - Config building

/// Renders a ``ProxyServer`` WireGuard-family server into the two artifacts
/// the engine consumes: a wg-quick style `.conf` (human-facing, import/export)
/// and the UAPI `set=1` script pushed into a running `amneziawg-go` daemon.
///
/// AmneziaWG's daemon does not read config files at all — the `awg` tool does
/// the file→UAPI translation. We speak UAPI directly so no extra tool binary
/// is needed, and produce the `.conf` only for export/compat.
public enum AmneziaWGConfigBuilder {

    /// Problems that would make the config *silently* fail — packets dropped
    /// by the server with no error anywhere. Surface these at import/connect
    /// instead of letting the user discover a dead tunnel.
    public static func validate(server: ProxyServer, mtu: Int = 1420) -> [String] {
        var problems: [String] = []
        guard let profile = server.wgProfile else {
            problems.append("missing peer profile (server public key)")
            return problems
        }
        if !isValidWGKey(profile.peerPublicKey) {
            problems.append("peer public key is not a 32-byte base64 key")
        }
        if !isValidWGKey(server.credential) {
            problems.append("private key is not a 32-byte base64 key")
        }
        if let psk = profile.presharedKey, !isValidWGKey(psk) {
            problems.append("preshared key is not a 32-byte base64 key")
        }
        if profile.allowedIPs.isEmpty {
            problems.append("AllowedIPs is empty — nothing would route into the tunnel")
        }
        if let mtu = profile.mtu, mtu <= 0 || mtu > 65535 {
            // The tunnel settings take this number as the interface MTU: 0 or a
            // negative value is not "auto", it is an interface that carries
            // nothing, and a link-local-sized one breaks every handshake.
            problems.append("MTU (\(mtu)) is not usable — leave it unset or pick 576…1500")
        }
        if let keepAlive = profile.keepAlive, keepAlive < 0 || keepAlive > 65535 {
            // The daemon parses the interval as an unsigned range; a negative
            // one fails the whole IpcSet, so the tunnel would die with an
            // opaque UAPI error rather than a word here.
            problems.append("PersistentKeepalive (\(keepAlive)) is outside the 0…65535 the daemon parses")
        }
        if let mtu2 = profile.mtu { problems.append(contentsOf: validateObfuscation(server.awg, mtu: mtu2)) }
        else { problems.append(contentsOf: validateObfuscation(server.awg, mtu: mtu)) }
        return problems
    }

    private static func validateObfuscation(_ o: AWGObfuscation?, mtu: Int) -> [String] {
        guard let o else { return [] }
        var problems: [String] = []
        // What the daemon will actually accept: `jc`/`jmin`/`jmax` are parsed
        // with ParseUint(…, 32) and `S1…S4` with ParseUint(…, 16)
        // (device/uapi.go of the pinned amneziawg-go). A negative or oversized
        // value fails the whole IpcSet — the import looked fine, and the tunnel
        // then died with an error the user cannot act on.
        for (name, value) in [("Jc", o.junkPackets), ("Jmin", o.junkMin), ("Jmax", o.junkMax)] {
            if let value, value < 0 || value > 4_294_967_295 {
                problems.append("\(name) (\(value)) is outside the 0…4294967295 the daemon parses")
            }
        }
        for (name, value) in [("S1", o.initPadding), ("S2", o.responsePadding),
                              ("S3", o.cookiePadding), ("S4", o.transportPadding)] {
            if let value, value < 0 || value > 65_535 {
                problems.append("\(name) (\(value)) is outside the 0…65535 the daemon parses")
            }
        }
        // A junk packet at or above the MTU gets IP-fragmented — a DPI
        // signature no legit flow produces. Refuse, don't warn: the server
        // can't be reached *discreetly* with this config, which is the point.
        if let jmax = o.junkMax, jmax >= mtu {
            problems.append("Jmax (\(jmax)) ≥ MTU (\(mtu)) — junk packets will be fragmented; set Jmax below \(mtu)")
        }
        if let jmin = o.junkMin, let jmax = o.junkMax, jmin > jmax {
            problems.append("Jmin (\(jmin)) > Jmax (\(jmax))")
        }
        // A trap documented by AmneziaWG: this coincidence makes the 148-byte
        // initiation and the 92-byte response the same wire size again,
        // re-enabling the size-classification the padding exists to defeat.
        if let s1 = o.initPadding, let s2 = o.responsePadding, s1 + 56 == s2 {
            problems.append("S1 + 56 = S2 (\(s1) + 56 = \(s2)) — initiation and response packets become indistinguishable by size; change one")
        }
        // S4 rides the wire as a u8 padding length — above 255 the daemon
        // rejects the whole config with an obscure UAPI error.
        if let s4 = o.transportPadding, s4 > 255 {
            problems.append("S4 (\(s4)) is above the 255-byte transport-padding limit")
        }
        if let key = o.headerProtectionKey {
            if hexKey(key) == nil {
                problems.append("HeaderProtectionKey is not a 32-byte key (base64 or hex)")
            }
            // amneziawg-go: header protection needs every padding S1–S4 ≥ 12.
            let paddings = [("S1", o.initPadding), ("S2", o.responsePadding),
                            ("S3", o.cookiePadding), ("S4", o.transportPadding)]
            let short = paddings.filter { ($0.1 ?? 0) < 12 }
                .map { "\($0.0) = \($0.1.map(String.init) ?? "unset")" }
            if !short.isEmpty {
                problems.append("header protection needs S1–S4 ≥ 12 (\(short.joined(separator: ", ")))")
            }
        }
        // 3.x ranges ride the wire as 16-bit values.
        let shortRanges: [(String, String?)] = [
            ("ContentPaddingAddition", o.contentPaddingAddition), ("RekeyAfterTime", o.rekeyAfterTime),
            ("RekeyTimeout", o.rekeyTimeout), ("RejectAfterTime", o.rejectAfterTime),
            ("KeepaliveTimeout", o.keepaliveTimeout), ("MaxHandshakeAttempts", o.maxHandshakeAttempts),
        ]
        for (name, raw) in shortRanges {
            if let raw, parseRange(raw, max: UInt32(UInt16.max)) == nil {
                problems.append("\(name) = \(raw) is not a number or range up to 65535")
            }
        }
        // Overlapping header ranges make packets unclassifiable — the engine
        // drops them silently (no log line, no error).
        let headers: [(String, String?)] = [("H1", o.header1), ("H2", o.header2),
                                            ("H3", o.header3), ("H4", o.header4)]
        var ranges: [(String, ClosedRange<UInt32>)] = []
        for (name, raw) in headers {
            // An unset header keeps WireGuard's default type value — legal
            // (1.0 configs often set only junk and padding).
            guard let raw else { continue }
            guard let r = parseHeaderRange(raw) else {
                problems.append("\(name) = \(raw) is not a number or range")
                continue
            }
            for (otherName, other) in ranges where other.overlaps(r) {
                problems.append("\(name) range \(raw) overlaps \(otherName) range — packets would be dropped as unclassifiable")
            }
            ranges.append((name, r))
        }
        return problems
    }

    /// Legal configs known to misbehave — logged at connect instead of refused,
    /// since the server side isn't the user's to change.
    public static func warnings(server: ProxyServer) -> [String] {
        guard let o = server.awg, o.randomTrailers == true else { return [] }
        // amneziawg-go#186: with RandomTrailers on, a transport packet whose
        // random prefix lands inside an H1–H3 range is classified as a
        // handshake and silently dropped — loss ≈ 1 − ∏(1 − width/2³²).
        var keep = 1.0
        for raw in [o.header1, o.header2, o.header3] {
            guard let raw, let r = parseHeaderRange(raw) else { continue }
            keep *= 1 - (Double(r.upperBound) - Double(r.lowerBound) + 1) / 4_294_967_296
        }
        let loss = 1 - keep
        guard loss > 0.001 else { return [] }
        return [String(format: "RandomTrailers with wide H1–H3 ranges drops ~%.1f%% of packets (amneziawg-go #186) — the server should narrow those ranges", loss * 100)]
    }

    /// `"12345"` → that value; `"12345-12399"` → the inclusive range. Values
    /// above UInt32.max are rejected (H* are 32-bit on the wire).
    /// Internal so the unit tests can exercise it directly.
    static func parseHeaderRange(_ raw: String) -> ClosedRange<UInt32>? {
        parseRange(raw, max: UInt32.max)
    }

    /// A value or `lo-hi` range (decimal or 0x-hex), bounded by `max`.
    static func parseRange(_ raw: String, max: UInt32) -> ClosedRange<UInt32>? {
        func value(_ s: String) -> UInt32? {
            let t = s.trimmingCharacters(in: .whitespaces)
            let v: UInt32?
            if t.hasPrefix("0x") { v = UInt32(t.dropFirst(2), radix: 16) } else { v = UInt32(t) }
            return v.flatMap { $0 <= max ? $0 : nil }
        }
        if let dash = raw.firstIndex(of: "-") {
            guard let lo = value(String(raw[raw.startIndex..<dash])),
                  let hi = value(String(raw[raw.index(after: dash)...])), lo <= hi else { return nil }
            return lo...hi
        }
        guard let v = value(raw) else { return nil }
        return v...v
    }

    /// A key in the lowercase hex the UAPI requires (amneziawg-go decodes
    /// every key with FromHex). Conf files and links carry base64 (44 chars);
    /// an already-hex key (64 chars) passes through. Nil when neither is 32 bytes.
    static func hexKey(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.count == 64, t.allSatisfy(\.isHexDigit) { return t.lowercased() }
        guard let data = Data(base64Encoded: t), data.count == 32 else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    /// A WireGuard key is 32 bytes, base64 → exactly 44 chars ending in '='.
    /// Ровно то, что принимает `hexKey` — то есть и 44-символьный base64, и
    /// готовые 64 hex-символа: amneziawg-go декодирует каждый ключ через
    /// FromHex, и `hexKey` уже пробирает hex насквозь. Проверять narrower,
    /// чем строит билдер, — значит ругаться на конфиг, который работает.
    static func isValidWGKey(_ s: String) -> Bool {
        hexKey(s) != nil
    }

    /// The address the utun must carry: the first usable IPv4 of the profile's
    /// own interface Address, without its prefix length. The server accepts
    /// inner packets only from the addresses it assigned this peer (its
    /// AllowedIPs), so a utun addressed from any other range completes the
    /// handshake and then has every packet dropped. Nil when the profile names
    /// no usable IPv4 (this-network, loopback and multicast/reserved are
    /// refused).
    ///
    /// `wgAddress` holds the whole `Address` list — a dual-stack profile
    /// carries `fd42::2/128, 10.8.1.2/32` in either order, and taking only the
    /// first entry left the IPv4 behind.
    public static func tunnelIPv4(server: ProxyServer) -> String? {
        for entry in tunnelAddresses(server) {
            let ip = addressPart(entry)
            guard DirectResolver.isIPv4(ip),
                  let first = ip.split(separator: ".").first.flatMap({ Int($0) }),
                  first != 0, first != 127, first < 224 else { continue }
            return ip
        }
        return nil
    }

    /// The profile's own IPv6 interface address, with its prefix (`/128`) —
    /// the same argument as for IPv4: it is the address the server assigned,
    /// so a made-up one routes IPv6 nowhere. Nil when the profile names none.
    public static func tunnelIPv6(server: ProxyServer) -> String? {
        tunnelAddresses(server).first { addressPart($0).contains(":") }
    }

    /// The interface addresses a profile names, as written (with prefixes).
    static func tunnelAddresses(_ server: ProxyServer) -> [String] {
        (server.userData?["wgAddress"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func addressPart(_ entry: String) -> String {
        String(entry.split(separator: "/", maxSplits: 1).first ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The range used when a profile names no IPv4 address of its own. The
    /// server may refuse it — this is "connect anyway", not a guess that
    /// usually works; re-importing the full config is the real fix.
    public static let fallbackTunAddress = "172.29.0.1"

    // MARK: UAPI script

    /// The `set=1` script for the running daemon. Key names and value formats
    /// are exactly what amneziawg-go's UAPI parser (device/uapi.go) accepts:
    ///   * `private_key`, `public_key`, `preshared_key`,
    ///     `header_protection_key` — lowercase HEX. Conf files carry base64;
    ///     the conversion is what the `awg` tool does on the way in, and a
    ///     base64 key is rejected outright (`FromHex`), i.e. no session.
    ///   * `jc/jmin/jmax`, `s1..s4` — integers; `h1..h4` — u32 ranges;
    ///     `i1..i5` — CPS strings;
    ///   * `content_padding_addition`, `rekey_after_time`, `rekey_timeout`,
    ///     `reject_after_time`, `keepalive_timeout`, `max_handshake_attempts`,
    ///     `persistent_keepalive_interval` — u16 ranges;
    ///   * `random_trailers`, `disable_cookies` — booleans (ParseBool);
    ///   * `endpoint`, `replace_allowed_ips`, `allowed_ip`, `protocol_version=1`.
    ///
    /// Empty parameters are omitted, not sent as blanks — the engine rejects
    /// `h1=` with an empty value, and a plain-WireGuard server needs the
    /// obfuscation lines absent, not present-but-empty.
    ///
    /// `endpointAddress` replaces the server's address on the `endpoint=`
    /// line: the engine parses that value with netip.ParseAddrPort, so a
    /// domain is rejected outright (`awg setconf` resolves names before it
    /// speaks UAPI) — the caller resolves a domain endpoint first.
    public static func makeUAPISetScript(server: ProxyServer, endpointAddress: String? = nil) throws -> String {
        guard let profile = server.wgProfile else {
            throw ParseError.awgConfig("no peer profile")
        }
        guard let privateKey = hexKey(server.credential) else {
            throw ParseError.awgConfig("private key is not a 32-byte base64 key")
        }
        guard let publicKey = hexKey(profile.peerPublicKey) else {
            throw ParseError.awgConfig("peer public key is not a 32-byte base64 key")
        }
        var lines: [String] = []
        lines.append("set=1")
        lines.append("private_key=\(privateKey)")
        if let o = server.awg {
            func num(_ v: Int?) -> String? { v.map(String.init) }
            func text(_ key: String, _ v: String?) {
                if let v, !v.isEmpty { lines.append("\(key)=\(v)") }
            }
            if let v = num(o.junkPackets) { lines.append("jc=\(v)") }
            if let v = num(o.junkMin) { lines.append("jmin=\(v)") }
            if let v = num(o.junkMax) { lines.append("jmax=\(v)") }
            if let v = num(o.initPadding) { lines.append("s1=\(v)") }
            if let v = num(o.responsePadding) { lines.append("s2=\(v)") }
            if let v = num(o.cookiePadding) { lines.append("s3=\(v)") }
            if let v = num(o.transportPadding) { lines.append("s4=\(v)") }
            for (idx, raw) in [o.header1, o.header2, o.header3, o.header4].enumerated() {
                text("h\(idx + 1)", raw)
            }
            for (idx, raw) in o.specialHandshakes.prefix(5).enumerated() {
                text("i\(idx + 1)", raw)
            }
            if let raw = o.headerProtectionKey, !raw.isEmpty {
                guard let key = hexKey(raw) else {
                    throw ParseError.awgConfig("HeaderProtectionKey is not a 32-byte key")
                }
                lines.append("header_protection_key=\(key)")
            }
            text("content_padding_addition", o.contentPaddingAddition)
            text("rekey_after_time", o.rekeyAfterTime)
            text("rekey_timeout", o.rekeyTimeout)
            text("reject_after_time", o.rejectAfterTime)
            text("keepalive_timeout", o.keepaliveTimeout)
            text("max_handshake_attempts", o.maxHandshakeAttempts)
            if let v = o.randomTrailers { lines.append("random_trailers=\(v)") }
            if let v = o.disableCookies { lines.append("disable_cookies=\(v)") }
        }
        lines.append("replace_peers=true")
        lines.append("public_key=\(publicKey)")
        if let psk = profile.presharedKey, !psk.isEmpty {
            guard let key = hexKey(psk) else {
                throw ParseError.awgConfig("preshared key is not a 32-byte base64 key")
            }
            lines.append("preshared_key=\(key)")
        }
        let endpointHost = endpointAddress ?? server.address
        lines.append("endpoint=\(endpointHost.contains(":") ? "[\(endpointHost)]" : endpointHost):\(server.port)")
        if let ka = profile.keepAlive { lines.append("persistent_keepalive_interval=\(ka)") }
        lines.append("replace_allowed_ips=true")
        for ip in profile.allowedIPs where !ip.isEmpty { lines.append("allowed_ip=\(ip)") }
        lines.append("protocol_version=1")
        lines.append("")   // UAPI scripts end with a blank line
        return lines.joined(separator: "\n")
    }

    // MARK: Interface byte counters

    /// Cumulative interface byte counters parsed from `netstat -ib` output
    /// (kept pure so it's unit-testable; the caller shells out). macOS column
    /// layout differs between release builds, so the row is located by the
    /// interface *name* column and the byte columns are picked from the
    /// header line rather than assumed.
    public static func parseNetstatCounters(_ output: String, interface: String) -> (up: Int64, down: Int64)? {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 2 else { return nil }
        let header = lines.removeFirst()
        let cols = header.split(separator: " ", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let nameCol = cols.firstIndex(of: "Name"),
              cols.contains("Ibytes"), cols.contains("Obytes") else { return nil }
        // The trailing block after the Network/Address columns is fixed —
        // Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll — but the Address column
        // is blank on `<Link#N>` rows, so absolute column indexes misalign.
        // Anchoring on the row's LAST seven fields is stable for both the
        // blank-Address and filled-Address shapes.
        let tail = 7
        let ibytesAt = 2, obytesAt = 5
        for line in lines {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count > nameCol, f[nameCol] == interface, f.count >= tail else { continue }
            let nums = Array(f.suffix(tail))
            guard let down = Int64(nums[ibytesAt]), let up = Int64(nums[obytesAt]) else { continue }
            return (up: up, down: down)
        }
        return nil
    }
}
