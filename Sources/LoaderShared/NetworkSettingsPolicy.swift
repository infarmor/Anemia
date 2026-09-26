import Foundation
import LoaderCore

/// Pure decisions behind every persistent network-setting change: what counts
/// as "ours", what may be recorded as the user's prior value, which services
/// may be touched at all, what a restore should do, and which settings can't
/// possibly work. No I/O. Shared by the helper (which changes settings) and
/// the app (which detects leftovers without root); unit tested against the
/// failure histories that left machines offline.
public enum NetworkSettingsPolicy {

    // MARK: - Ownership

    /// /24 prefixes of the tunnel endpoints the helper creates (xray and
    /// WireGuard-family sessions). A resolver inside them only answers while
    /// our utun exists.
    public static let ownedTunnelPrefixes: [String] = [
        prefix24(LoaderIdentifiers.defaultTunGateway),
        prefix24(LoaderIdentifiers.defaultAWGTunGateway)
    ]

    /// Addressing before helper 0.6.3. It is also the fake-IP range of
    /// sing-box/clash clients, so it only counts as a leftover of ours while
    /// no live interface holds an address in it.
    public static let legacyTunnelPrefixes = ["198.18.0"]

    public static func prefix24(_ ip: String) -> String {
        ip.split(separator: ".").prefix(3).joined(separator: ".")
    }

    public static func isOwnedResolver(_ ip: String) -> Bool {
        DirectResolver.isIPv4(ip) && ownedTunnelPrefixes.contains(prefix24(ip))
    }

    public static func isLegacyResolver(_ ip: String) -> Bool {
        DirectResolver.isIPv4(ip) && legacyTunnelPrefixes.contains(prefix24(ip))
    }

    /// Whether some live local interface holds an address in `ip`'s /24 —
    /// i.e. a tunnel that could actually answer on it exists right now.
    public static func isHeldLocally(_ ip: String, liveIPv4: Set<String>) -> Bool {
        let p = prefix24(ip)
        return liveIPv4.contains { prefix24($0) == p }
    }

    public static func isLoopbackHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "localhost" || h == "::1" || h.hasPrefix("127.")
    }

    // MARK: - Capturing the user's prior value

    /// The resolver list to record as a service's prior value. Our own tunnel
    /// resolvers never count as the user's configuration, and neither do
    /// legacy-range resolvers nothing local can answer on: a list made only of
    /// those is a leftover pin, whose real prior was automatic (DHCP).
    public static func sanitizePriorDNS(_ current: [String], liveIPv4: Set<String>) -> [String] {
        current.filter { ip in
            if isOwnedResolver(ip) { return false }
            if isLegacyResolver(ip) && !isHeldLocally(ip, liveIPv4: liveIPv4) { return false }
            return true
        }
    }

    /// The proxy state to record as a service's prior value. A loopback proxy
    /// on the port we are about to apply, on the engine's default port, or on
    /// a port nothing listens on is a leftover engine pin — recording it would
    /// make every later restore re-apply a dead proxy. A live loopback proxy
    /// on another port (a user's own local proxy app) is kept.
    public static func sanitizePriorProxy(_ current: ProxySetting, applyingPort: Int,
                                          isPortLive: (Int) -> Bool) -> ProxySetting {
        guard current.enabled, isLoopbackHost(current.host) else { return current }
        if current.port == applyingPort
            || current.port == LoaderIdentifiers.defaultSocksPort
            || !isPortLive(current.port) {
            return .off
        }
        return current
    }

    // MARK: - Restoring

    public enum DNSRestore: Equatable, Sendable {
        /// Put these resolvers back (empty = automatic).
        case restore([String])
        /// The setting no longer holds our value — the user changed it; leave it.
        case forget
        /// The state can't be read right now; keep the entry and retry later.
        case retryLater
    }

    public static func dnsRestoreAction(entry: NetworkJournal.DNSEntry, current: [String]?,
                                        serviceExists: Bool) -> DNSRestore {
        guard let current else { return serviceExists ? .retryLater : .forget }
        let stillOurs: Bool
        if !entry.applied.isEmpty {
            stillOurs = current == entry.applied
        } else {
            // Legacy entry: what we applied is unknown, but only tunnel-range
            // resolvers were ever set by those helpers.
            stillOurs = !current.isEmpty && current.allSatisfy { isOwnedResolver($0) || isLegacyResolver($0) }
        }
        return stillOurs ? .restore(entry.prior) : .forget
    }

    public enum ProxyRestore: Equatable, Sendable {
        case restore(ProxySetting)
        case forget
        case retryLater
    }

    public static func proxyRestoreAction(entry: NetworkJournal.ProxyEntry, current: ProxySetting?,
                                          serviceExists: Bool) -> ProxyRestore {
        guard let current else { return serviceExists ? .retryLater : .forget }
        let stillOurs = current.enabled
            && isLoopbackHost(current.host)
            && (entry.applied.port == 0 || current.port == entry.applied.port)
        return stillOurs ? .restore(entry.prior) : .forget
    }

    // MARK: - Dead pins (no ledger entry)

    /// A resolver list that can't answer anything: every entry sits on one of
    /// our tunnel ranges and no local interface holds that range. The machine
    /// is name-resolution-dead until it is reset. The legacy range is only
    /// considered on explicit repair — at boot a fake-IP VPN that owns it
    /// simply hasn't connected yet.
    public static func isDeadDNSPin(_ servers: [String], liveIPv4: Set<String>, includeLegacy: Bool) -> Bool {
        !servers.isEmpty && servers.allSatisfy { ip in
            (isOwnedResolver(ip) || (includeLegacy && isLegacyResolver(ip)))
                && !isHeldLocally(ip, liveIPv4: liveIPv4)
        }
    }

    /// An enabled loopback proxy nothing listens on: every proxy-aware app is
    /// cut off while it stays set.
    public static func isDeadProxyPin(_ proxy: ProxySetting, isPortLive: (Int) -> Bool) -> Bool {
        proxy.enabled && isLoopbackHost(proxy.host) && (proxy.port <= 0 || !isPortLive(proxy.port))
    }

    // MARK: - networksetup output

    /// `networksetup -getdnsservers`: resolver lines only. The "automatic"
    /// state is detected structurally (no IP literal), never by the English
    /// sentence, which is localized on some systems.
    public static func parseDNSServers(_ output: String) -> [String] {
        output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && (DirectResolver.isIPv4($0) || $0.contains(":")) }
    }

    /// `networksetup -getsocksfirewallproxy`: "Enabled: Yes/No", "Server:",
    /// "Port:". Nil when unreadable — including an enabled state without a
    /// usable host/port, which is a misread, not a capture.
    public static func parseSocksProxy(_ output: String) -> ProxySetting? {
        var enabled = false
        var sawEnabled = false
        var host = ""
        var port = ""
        for line in output.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Enabled:") {
                sawEnabled = true
                enabled = t.lowercased().contains("yes")
            } else if t.hasPrefix("Server:") {
                host = t.dropFirst("Server:".count).trimmingCharacters(in: .whitespaces)
            } else if t.hasPrefix("Port:") {
                port = t.dropFirst("Port:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        guard sawEnabled else { return nil }
        if enabled, host.isEmpty || port.isEmpty || !port.allSatisfy(\.isNumber) { return nil }
        return ProxySetting(enabled: enabled, host: host, port: Int(port) ?? 0)
    }

    // MARK: - Which services may be touched

    public struct NetworkService: Equatable, Sendable {
        public let name: String
        public let device: String
        public let enabled: Bool

        public init(name: String, device: String, enabled: Bool) {
            self.name = name
            self.device = device
            self.enabled = enabled
        }
    }

    /// Parse `networksetup -listnetworkserviceorder`:
    ///
    ///     (3) Wi-Fi
    ///     (Hardware Port: Wi-Fi, Device: en0)
    ///     (*) Old Service                  ← disabled
    ///     (Hardware Port: …, Device: )     ← no device: a VPN service
    public static func parseServiceOrder(_ output: String) -> [NetworkService] {
        var services: [NetworkService] = []
        var pending: (name: String, enabled: Bool)?
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("(Hardware Port:"), let p = pending {
                var device = ""
                if let r = line.range(of: "Device:", options: .backwards) {
                    device = line[r.upperBound...]
                        .trimmingCharacters(in: CharacterSet(charactersIn: " )"))
                }
                services.append(NetworkService(name: p.name, device: device, enabled: p.enabled))
                pending = nil
                continue
            }
            guard line.hasPrefix("("), let close = line.firstIndex(of: ")") else { continue }
            let tag = line[line.index(after: line.startIndex)..<close]
            guard tag == "*" || (!tag.isEmpty && tag.allSatisfy(\.isNumber)) else { continue }
            let name = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            pending = (name, tag != "*")
        }
        return services
    }

    /// Services an override may touch: enabled and backed by a hardware
    /// device. A VPN service (a third-party client such as Happ, IPSec, L2TP)
    /// has no device — its resolver and proxy belong to that VPN, and
    /// rewriting them breaks it.
    public static func overridableServices(_ services: [NetworkService]) -> [String] {
        services.filter { $0.enabled && !$0.device.isEmpty }.map(\.name)
    }
}
