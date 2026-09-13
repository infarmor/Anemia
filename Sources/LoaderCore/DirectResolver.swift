import Foundation

/// Direct (getaddrinfo) DNS resolution used OUTSIDE the tunnel: the VPN
/// server's own address must be known before the engine can provide any
/// tunneled answers, so its resolution can never depend on the proxy.
public enum DirectResolver {

    /// Whether the string is already a dotted-quad IPv4 literal.
    /// One split for both the octet count and the value check — counting with
    /// `omittingEmptySubsequences: false` while validating without it let
    /// malformed strings like "1..2.3" or "1.2.3." pass as valid IPs.
    /// Octets must be plain ASCII digits: `Int("+4")` parses a leading sign,
    /// so a `"+1.2.3.4"` from a malformed/malicious link would masquerade
    /// as a resolvable literal and skip resolution entirely. A leading zero
    /// is likewise rejected: BSD's inet_aton (ifconfig, route) reads
    /// "010.0.0.1" as OCTAL 8.0.0.1, so the programmed address would differ
    /// from the validated/collision-checked string.
    public static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            guard part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
            guard part.count == 1 || part.first != "0" else { return false }
            guard let v = Int(part) else { return false }
            return (0...255).contains(v)
        }
    }

    /// Whether the address falls inside 198.18.0.0/15 — the fake-IP pool that
    /// sing-box/clash/mihomo clients hand out from their DNS. A resolution
    /// landing there is never a real destination: the system resolver is
    /// answering through a foreign VPN's fake-IP machinery, and pinning such
    /// an address as the engine's server would send the encrypted connection
    /// into that VPN (or nowhere at all).
    public static func isFakeIP(_ s: String) -> Bool {
        // Only a literal dotted-quad can be a fake-IP answer. This guard is
        // also applied to the HOST argument of ipv4(), and a hostname that
        // merely starts with "198.18." (e.g. 198.18.mirror.example.com) is a
        // real, resolvable domain — the prefix test alone made such servers
        // read as unresolvable without a single lookup ever happening.
        guard s.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return false }
        return s.hasPrefix("198.18.") || s.hasPrefix("198.19.")
    }

    /// Resolve a hostname to IPv4 addresses via getaddrinfo — the system
    /// resolver, no tunnel involvement. Fake-IP answers are filtered out so a
    /// concurrently running fake-IP VPN can't poison the pin.
    public static func ipv4(_ host: String) -> [String] {
        guard !isIPv4(host), !isFakeIP(host) else { return [] }
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
            ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
        )
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0 else { return [] }
        defer { freeaddrinfo(res) }

        var ips: [String] = []
        var node = res
        while let cur = node {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(cur.pointee.ai_addr, cur.pointee.ai_addrlen,
                           &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                let bytes = buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                let ip = String(decoding: bytes, as: UTF8.self)
                if !ips.contains(ip), !isFakeIP(ip) { ips.append(ip) }
            }
            node = cur.pointee.ai_next
        }
        return ips
    }
}