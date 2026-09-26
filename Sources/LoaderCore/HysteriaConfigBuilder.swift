import Foundation

/// Builds the client YAML config for the standalone `hysteria` engine.
///
/// Xray-core cannot dial the hysteria protocol (QUIC, its own framing), so a
/// hysteria server runs as its own process next to xray: the hysteria client
/// connects to the server and serves a local SOCKS5 bridge, and the xray
/// config routes everything through a `socks` outbound pointed at that
/// bridge. This builder is the pure half — config text + validation; the
/// app-side ``HysteriaController`` owns the process lifecycle.
///
/// Both protocol generations are covered: `hysteria2` (the engine's native
/// protocol) and `hysteria` v1 (config generated for a v1 binary, but the
/// connect path refuses to launch it against the v2-only binary — a version
/// mismatch fails with a clear error, not silent garbage).
public enum HysteriaConfigBuilder {

    // MARK: - Errors

    public enum BuilderError: LocalizedError, Equatable {
        case missingAuth
        case unsupportedProtocol(String)

        public var errorDescription: String? {
            switch self {
            case .missingAuth:
                return "Hysteria server carries no auth/password — re-import the link."
            case .unsupportedProtocol(let proto):
                return "Hysteria protocol v1 is not supported by the bundled engine path — use a hysteria2 (hy2://) link. (\(proto))"
            }
        }
    }

    // MARK: - Validation

    /// Up-front problems that would fail only silently on the wire otherwise.
    public static func validate(server: ProxyServer) -> [String] {
        var problems: [String] = []
        if server.credential.isEmpty { problems.append("auth/password is empty") }
        if (1...65535).contains(server.port) == false { problems.append("port \(server.port) is out of range") }
        if server.address.isEmpty { problems.append("server address is empty") }
        if let hop = server.userData?["portHopping"], !hop.isEmpty, !isValidPortSpec(hop) {
            problems.append("port hopping spec '\(hop)' is not a port list like 443,20000-50000")
        }
        if server.proto == .hysteria {
            // The v1 YAML below is generated for completeness, but the
            // Homebrew/bundled binary is the v2 engine: it would reject the
            // config (or worse, parse it wrongly). Say it at import/connect.
            problems.append("hysteria protocol v1 requires the legacy hysteria v1 client binary")
        }
        return problems
    }

    // MARK: - Config text

    /// The client YAML. `socksPort` is the local bridge port the controller
    /// picked — the same port the xray socks outbound must target.
    public static func makeClientConfig(server: ProxyServer, socksPort: Int) throws -> String {
        guard !server.credential.isEmpty else { throw BuilderError.missingAuth }
        let host = server.address.contains(":") && !server.address.hasPrefix("[")
            ? "[\(server.address)]"
            : server.address
        let endpoint = "\(host):\(portSpec(for: server))"

        var lines: [String] = []
        let q = yamlString
        switch server.proto {
        case .hysteria2:
            lines.append("server: \(q(endpoint))")
            lines.append("auth: \(q(server.credential))")
            lines.append("tls:")
            if let sni = server.sni, !sni.isEmpty { lines.append("  sni: \(q(sni))") }
            if server.allowInsecure { lines.append("  insecure: true") }
            if !server.alpn.isEmpty { lines.append("  alpn: \(q(server.alpn.joined(separator: ",")))") }
            // The client's field is `pinSHA256` (checked against the hysteria
            // 2.12 binary). The old `pinnedSHA256` spelling was silently
            // ignored — a link's certificate pin never took effect.
            if let pin = server.userData?["pinSHA256"], !pin.isEmpty {
                lines.append("  pinSHA256: \(q(pin))")
            }
            if let obfs = server.userData?["obfs"], !obfs.isEmpty,
               let obfsPass = server.userData?["obfsPassword"], !obfsPass.isEmpty {
                lines.append("obfs:")
                lines.append("  type: \(q(obfs))")
                lines.append("  salamander:")
                lines.append("    password: \(q(obfsPass))")
            }
        case .hysteria:
            // v1 shape (kept for tooling/tests; the connect path refuses to
            // run it against a v2 binary — see validate).
            lines.append("server: \(q(endpoint))")
            lines.append("protocol: \(q(server.userData?["protocol"] ?? "udp"))")
            if let up = server.userData?["upmbps"] { lines.append("up: \(q("\(up) Mbps"))") }
            if let down = server.userData?["downmbps"] { lines.append("down: \(q("\(down) Mbps"))") }
            lines.append("auth_str: \(q(server.credential))")
            lines.append("tls:")
            if let sni = server.sni, !sni.isEmpty { lines.append("  sni: \(q(sni))") }
            if server.allowInsecure { lines.append("  insecure: true") }
            if !server.alpn.isEmpty { lines.append("  alpn: \(q(server.alpn.joined(separator: ",")))") }
            if let obfs = server.userData?["obfs"], !obfs.isEmpty {
                lines.append("obfs: \(q(obfs))")
                if let p = server.userData?["obfsPassword"], !p.isEmpty {
                    lines.append("obfs_param: \(q(p))")
                }
            }
        default:
            throw BuilderError.unsupportedProtocol(server.proto.rawValue)
        }
        // The bridge xray routes through. No bandwidth section: without one
        // hysteria2 uses BBR congestion control, which outperforms guessed
        // rate limits.
        lines.append("socks5:")
        lines.append("  listen: \(q("127.0.0.1:\(socksPort)"))")
        return (lines.joined(separator: "\n") + "\n")
    }

    /// `443`, `20000-50000`, `443,20000-50000` — every port 1…65535, ranges ascending.
    public static func isValidPortSpec(_ spec: String) -> Bool {
        let items = spec.split(separator: ",", omittingEmptySubsequences: false)
        guard !items.isEmpty else { return false }
        return items.allSatisfy { item in
            let bounds = item.split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(bounds.count) else { return false }
            let ports = bounds.compactMap { b -> Int? in
                guard !b.isEmpty, b.count <= 5, b.allSatisfy(\.isNumber) else { return nil }
                return Int(b).flatMap { (1...65535).contains($0) ? $0 : nil }
            }
            return ports.count == bounds.count && (ports.count == 1 || ports[0] <= ports[1])
        }
    }

    /// The client's server port field: the link's port, widened by its port
    /// hopping spec (the hysteria client hops across every listed port).
    static func portSpec(for server: ProxyServer) -> String {
        guard server.proto == .hysteria2, let hop = server.userData?["portHopping"],
              !hop.isEmpty, isValidPortSpec(hop) else { return String(server.port) }
        let covers = hop.split(separator: ",").contains { item in
            let b = item.split(separator: "-").compactMap { Int($0) }
            return b.count == 1 ? b[0] == server.port : (b.count == 2 && (b[0]...b[1]).contains(server.port))
        }
        return covers ? hop : "\(server.port),\(hop)"
    }

    /// Emit a YAML scalar as a double-quoted string — YAML accepts the JSON
    /// string grammar, so JSON-escaping guarantees a hostile auth password
    /// (quotes, colons, newlines, `#`) can't break the document structure.
    private static func yamlString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "\"\"" }
        return String(data: data, encoding: .utf8) ?? "\"\""
    }
}