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
        if o.headerProtectionKey != nil || o.contentPaddingAddition != nil { return .v3 }
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
    /// Random extra padding inside encrypted payloads (3.0+).
    public var contentPaddingAddition: Int?
    /// Pad transport packets up to the MTU with random values (3.1+).
    public var randomTrailers: Bool?
    /// Disable cookiereply responses (3.1+).
    public var disableCookies: Bool?

    public init(
        junkPackets: Int? = nil, junkMin: Int? = nil, junkMax: Int? = nil,
        initPadding: Int? = nil, responsePadding: Int? = nil,
        cookiePadding: Int? = nil, transportPadding: Int? = nil,
        header1: String? = nil, header2: String? = nil,
        header3: String? = nil, header4: String? = nil,
        specialHandshakes: [String] = [],
        headerProtectionKey: String? = nil,
        contentPaddingAddition: Int? = nil,
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
        self.randomTrailers = randomTrailers
        self.disableCookies = disableCookies
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
        if let mtu2 = profile.mtu { problems.append(contentsOf: validateObfuscation(server.awg, mtu: mtu2)) }
        else { problems.append(contentsOf: validateObfuscation(server.awg, mtu: mtu)) }
        return problems
    }

    private static func validateObfuscation(_ o: AWGObfuscation?, mtu: Int) -> [String] {
        guard let o else { return [] }
        var problems: [String] = []
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
        if o.headerProtectionKey != nil, (o.transportPadding ?? 0) < 12 {
            problems.append("header protection needs S4 ≥ 12 (have \(o.transportPadding.map(String.init) ?? "unset"))")
        }
        // Overlapping header ranges make packets unclassifiable — the engine
        // drops them silently (no log line, no error).
        let headers: [(String, String?)] = [("H1", o.header1), ("H2", o.header2),
                                            ("H3", o.header3), ("H4", o.header4)]
        var ranges: [(String, ClosedRange<UInt32>)] = []
        for (name, raw) in headers {
            guard let raw, let r = parseHeaderRange(raw) else {
                problems.append("\(name) = \(raw ?? "?") is not a number or range")
                continue
            }
            for (otherName, other) in ranges where other.overlaps(r) {
                problems.append("\(name) range \(raw) overlaps \(otherName) range — packets would be dropped as unclassifiable")
            }
            ranges.append((name, r))
        }
        return problems
    }

    /// `"12345"` → that value; `"12345-12399"` → the inclusive range. Values
    /// above UInt32.max are rejected (H* are 32-bit on the wire).
    /// Internal so the unit tests can exercise it directly.
    static func parseHeaderRange(_ raw: String) -> ClosedRange<UInt32>? {
        func value(_ s: String) -> UInt32? {
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("0x"), let v = UInt32(t.dropFirst(2), radix: 16) { return v }
            if t.hasPrefix("0x") { return nil }
            return UInt32(t)
        }
        if let dash = raw.firstIndex(of: "-") {
            guard let lo = value(String(raw[raw.startIndex..<dash])),
                  let hi = value(String(raw[raw.index(after: dash)...])), lo <= hi else { return nil }
            return lo...hi
        }
        guard let v = value(raw) else { return nil }
        return v...v
    }

    /// A WireGuard key is 32 bytes, base64 → exactly 44 chars ending in '='.
    static func isValidWGKey(_ s: String) -> Bool {
        s.count == 44 && s.hasSuffix("=") && Data(base64Encoded: s)?.count == 32
    }

    // MARK: UAPI script

    /// The `set=1` script for the running daemon. Key names are the exact
    /// strings amneziawg-go's UAPI parser accepts (device/uapi.go):
    /// `jc/jmin/jmax`, `s1..s4`, `h1..h4` (UintRange), `i1..i5`,
    /// `header_protection_key`, `content_padding_addition`, `random_trailers`,
    /// `disable_cookies`; peer-level `public_key`, `preshared_key`,
    /// `endpoint`, `persistent_keepalive_interval`, `replace_allowed_ips`,
    /// `allowed_ip`, `protocol_version` (must be 1).
    ///
    /// Empty-string parameters are omitted, not sent as blanks — the engine
    /// rejects `h1=` with an empty value, and a plain-WireGuard server needs
    /// the obfuscation lines absent, not present-but-empty.
    public static func makeUAPISetScript(server: ProxyServer) throws -> String {
        guard let profile = server.wgProfile else {
            throw ParseError.awgConfig("no peer profile")
        }
        guard !profile.peerPublicKey.isEmpty else {
            throw ParseError.awgConfig("missing peer public key")
        }
        var lines: [String] = []
        lines.append("set=1")
        lines.append("private_key=\(server.credential)")
        if let o = server.awg {
            func num(_ v: Int?) -> String? { v.map(String.init) }
            if let v = num(o.junkPackets) { lines.append("jc=\(v)") }
            if let v = num(o.junkMin) { lines.append("jmin=\(v)") }
            if let v = num(o.junkMax) { lines.append("jmax=\(v)") }
            if let v = num(o.initPadding) { lines.append("s1=\(v)") }
            if let v = num(o.responsePadding) { lines.append("s2=\(v)") }
            if let v = num(o.cookiePadding) { lines.append("s3=\(v)") }
            if let v = num(o.transportPadding) { lines.append("s4=\(v)") }
            for (idx, raw) in [o.header1, o.header2, o.header3, o.header4].enumerated() {
                if let raw, !raw.isEmpty { lines.append("h\(idx + 1)=\(raw)") }
            }
            for (idx, raw) in o.specialHandshakes.prefix(5).enumerated() {
                if !raw.isEmpty { lines.append("i\(idx + 1)=\(raw)") }
            }
            if let v = o.headerProtectionKey, !v.isEmpty { lines.append("header_protection_key=\(v)") }
            if let v = num(o.contentPaddingAddition) { lines.append("content_padding_addition=\(v)") }
            if o.randomTrailers == true { lines.append("random_trailers=true") }
            if o.disableCookies == true { lines.append("disable_cookies=true") }
        }
        lines.append("replace_peers=true")
        lines.append("public_key=\(profile.peerPublicKey)")
        if let psk = profile.presharedKey, !psk.isEmpty { lines.append("preshared_key=\(psk)") }
        lines.append("endpoint=\(server.address):\(server.port)")
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
