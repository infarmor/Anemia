import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Split tunneling ("local bypass"): destinations that must leave through the
/// physical network, never the VPN — a local bank or government site that
/// refuses foreign IPs, a work network, a NAS on another subnet.
///
/// The user's raw lines are what persists (so nothing they typed is lost to a
/// validation change); ``SplitTunnelParser`` turns them into ``BypassEntry``
/// values at connect time, on both sides of the XPC boundary.
public struct SplitTunnelRules: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// One destination per line: an IPv4/IPv6 address or CIDR, or a domain
    /// (`example.com` also covers its subdomains).
    public var entries: [String]

    public init(enabled: Bool = true, entries: [String] = []) {
        self.enabled = enabled
        self.entries = entries
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        entries = (try? c.decode([String].self, forKey: .entries)) ?? []
    }

    /// The validated destinations this rule set routes around the VPN.
    public var activeEntries: [BypassEntry] {
        enabled ? SplitTunnelParser.parse(entries).entries : []
    }
}

/// One validated, normalized bypass destination.
public enum BypassEntry: Hashable, Sendable {
    /// IPv4 network in canonical CIDR form ("203.0.113.0/24", "198.51.100.7/32").
    case ipv4(String)
    /// IPv6 network in canonical CIDR form ("2001:db8::/32").
    case ipv6(String)
    /// Lowercase ASCII domain (IDN labels in punycode); covers subdomains.
    case domain(String)

    public var value: String {
        switch self {
        case .ipv4(let v), .ipv6(let v), .domain(let v): return v
        }
    }

    public var isDomain: Bool {
        if case .domain = self { return true }
        return false
    }
}

public enum SplitTunnelParser {

    public struct Rejection: Sendable, Equatable {
        public let line: String
        public let reason: String
    }

    public struct Result: Sendable, Equatable {
        public var entries: [BypassEntry]
        public var rejected: [Rejection]
    }

    /// Narrowest prefixes accepted: anything broader would route most of the
    /// internet around the tunnel — a VPN switched off by a typo.
    public static let minimumIPv4Prefix = 8
    public static let minimumIPv6Prefix = 16

    /// Networks a bypass may never cover: loopback (never tunneled anyway) and
    /// the helper's own tunnel ranges (routing them to the physical gateway
    /// would cut the tunnel's DNS and its engine link).
    static let reservedIPv4: [(network: UInt32, prefix: Int, reason: String)] = [
        (0x7F00_0000, 8, "loopback never goes through the VPN"),
        (0xAC1C_0000, 24, "that range is the VPN tunnel itself"),   // 172.28.0.0/24
        (0xAC1D_0000, 24, "that range is the VPN tunnel itself")    // 172.29.0.0/24
    ]

    /// Parse a free-form paste: newlines, commas, semicolons and whitespace all
    /// separate destinations; `#` starts a comment.
    public static func parse(text: String) -> Result {
        let lines = text.split(whereSeparator: \.isNewline).flatMap { line -> [String] in
            let code = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            return code.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " || $0 == "\t" }).map(String.init)
        }
        return parse(lines)
    }

    /// Parse stored lines (one destination each). Duplicates collapse; order is kept.
    public static func parse(_ lines: [String]) -> Result {
        var entries: [BypassEntry] = []
        var seen = Set<BypassEntry>()
        var rejected: [Rejection] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            switch parseEntry(line) {
            case .success(let entry):
                if seen.insert(entry).inserted { entries.append(entry) }
            case .failure(let reason):
                rejected.append(Rejection(line: line, reason: reason.message))
            }
        }
        return Result(entries: entries, rejected: rejected)
    }

    /// Split validated entries into what the helper routes by address and what
    /// it must resolve first.
    public static func partition(_ entries: [BypassEntry]) -> (networks: [String], domains: [String]) {
        var networks: [String] = []
        var domains: [String] = []
        for e in entries {
            if e.isDomain { domains.append(e.value) } else { networks.append(e.value) }
        }
        return (networks, domains)
    }

    struct Reason: Error { let message: String }

    static func parseEntry(_ input: String) -> Swift.Result<BypassEntry, Reason> {
        var s = input.lowercased()
        if let scheme = s.range(of: "://") { s = String(s[scheme.upperBound...]) }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }   // user@host

        // Bracketed IPv6 URL host: [2001:db8::1]:443/path
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            return parseIPv6(String(s[s.index(after: s.startIndex)..<close]), prefix: nil)
        }

        // Address with an optional prefix length.
        let slashParts = s.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let head = String(slashParts[0])
        let tail = slashParts.count > 1 ? String(slashParts[1]) : nil
        if head.contains(":"), head.filter({ $0 == ":" }).count > 1 {
            return parseIPv6(head, prefix: tail)
        }
        let hostPort = head.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let host = String(hostPort[0])
        if isIPv4Literal(host) {
            // A prefix only belongs to a bare address, not to host:port/path.
            return parseIPv4(host, prefix: hostPort.count == 1 ? tail : nil)
        }
        return parseDomain(host)
    }

    // MARK: IPv4

    static func isIPv4Literal(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    static func parseIPv4(_ address: String, prefix: String?) -> Swift.Result<BypassEntry, Reason> {
        var value: UInt32 = 0
        for part in address.split(separator: ".") {
            guard part.count <= 3, let octet = UInt32(part), octet <= 255,
                  part.count == 1 || part.first != "0" else {
                return .failure(Reason(message: "not a valid IPv4 address"))
            }
            value = value << 8 | octet
        }
        var bits = 32
        if let prefix {
            guard let p = Int(prefix), (0...32).contains(p) else {
                return .failure(Reason(message: "prefix length must be 0–32"))
            }
            bits = p
        }
        guard bits >= minimumIPv4Prefix else {
            return .failure(Reason(message: "too broad — /\(bits) would send most traffic around the VPN (use /\(minimumIPv4Prefix) or narrower)"))
        }
        let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
        let network = value & mask
        for reserved in reservedIPv4 {
            let common = min(bits, reserved.prefix)
            let commonMask: UInt32 = common == 0 ? 0 : ~UInt32(0) << (32 - common)
            if network & commonMask == reserved.network & commonMask {
                return .failure(Reason(message: reserved.reason))
            }
        }
        let dotted = [24, 16, 8, 0].map { String((network >> UInt32($0)) & 0xFF) }.joined(separator: ".")
        return .success(.ipv4("\(dotted)/\(bits)"))
    }

    // MARK: IPv6

    static func parseIPv6(_ address: String, prefix: String?) -> Swift.Result<BypassEntry, Reason> {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard !address.contains("%"), inet_pton(AF_INET6, address, &bytes) == 1 else {
            return .failure(Reason(message: "not a valid IPv6 address"))
        }
        var bits = 128
        if let prefix {
            guard let p = Int(prefix), (0...128).contains(p) else {
                return .failure(Reason(message: "prefix length must be 0–128"))
            }
            bits = p
        }
        guard bits >= minimumIPv6Prefix else {
            return .failure(Reason(message: "too broad — /\(bits) would send most IPv6 traffic around the VPN (use /\(minimumIPv6Prefix) or narrower)"))
        }
        if bytes == [UInt8](repeating: 0, count: 15) + [1] {
            return .failure(Reason(message: "loopback never goes through the VPN"))
        }
        for i in 0..<16 {
            let keep = max(0, min(8, bits - i * 8))
            bytes[i] &= keep == 8 ? 0xFF : UInt8(truncatingIfNeeded: 0xFF << (8 - keep))
        }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, bytes, &buf, socklen_t(buf.count)) != nil else {
            return .failure(Reason(message: "not a valid IPv6 address"))
        }
        let text = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return .success(.ipv6("\(text)/\(bits)"))
    }

    // MARK: Domains

    static func parseDomain(_ input: String) -> Swift.Result<BypassEntry, Reason> {
        var host = input
        if host.hasPrefix("*.") { host.removeFirst(2) }
        if host.hasPrefix(".") { host.removeFirst() }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return .failure(Reason(message: "empty domain")) }
        var labels: [String] = []
        for label in host.split(separator: ".", omittingEmptySubsequences: false) {
            guard !label.isEmpty else { return .failure(Reason(message: "not a valid domain")) }
            guard let ascii = Punycode.encodeLabel(String(label)) else {
                return .failure(Reason(message: "not a valid domain"))
            }
            guard ascii.count <= 63,
                  ascii.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }),
                  ascii.first != "-", ascii.last != "-" else {
                return .failure(Reason(message: "not a valid domain"))
            }
            labels.append(ascii)
        }
        let domain = labels.joined(separator: ".")
        guard domain.count <= 253 else { return .failure(Reason(message: "domain is too long")) }
        guard !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) else {
            return .failure(Reason(message: "not a valid IP address or domain"))
        }
        return .success(.domain(domain))
    }
}

/// RFC 3492 Punycode for internationalized domain labels ("пример" →
/// "xn--e1afmkfd"): routing rules match the ASCII form a TLS ClientHello
/// carries, so a Cyrillic domain typed by the user must be converted.
public enum Punycode {
    private static let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
    private static let initialBias = 72, initialN = 128

    /// Encode one label; ASCII labels pass through unchanged. Nil on overflow.
    public static func encodeLabel(_ label: String) -> String? {
        let scalars = label.unicodeScalars.map { Int($0.value) }
        guard scalars.contains(where: { $0 >= initialN }) else { return label }
        var output: [Character] = scalars.filter { $0 < initialN }.compactMap { UnicodeScalar($0).map(Character.init) }
        let basicCount = output.count
        var handled = basicCount
        if basicCount > 0 { output.append("-") }
        var n = initialN, delta = 0, bias = initialBias
        while handled < scalars.count {
            guard let m = scalars.filter({ $0 >= n }).min() else { return nil }
            let (step, o1) = (m - n).multipliedReportingOverflow(by: handled + 1)
            guard !o1 else { return nil }
            delta += step
            n = m
            for c in scalars {
                if c < n { delta += 1 }
                guard c == n else { continue }
                var q = delta
                var k = base
                while true {
                    let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                    if q < t { break }
                    output.append(digit(t + (q - t) % (base - t)))
                    q = (q - t) / (base - t)
                    k += base
                }
                output.append(digit(q))
                bias = adapt(delta, points: handled + 1, first: handled == basicCount)
                delta = 0
                handled += 1
            }
            delta += 1
            n += 1
        }
        return "xn--" + String(output)
    }

    private static func adapt(_ delta: Int, points: Int, first: Bool) -> Int {
        var d = first ? delta / damp : delta / 2
        d += d / points
        var k = 0
        while d > ((base - tMin) * tMax) / 2 {
            d /= base - tMin
            k += base
        }
        return k + ((base - tMin + 1) * d) / (d + skew)
    }

    private static func digit(_ d: Int) -> Character {
        d < 26 ? Character(UnicodeScalar(UInt8(97 + d))) : Character(UnicodeScalar(UInt8(22 + d)))
    }
}
