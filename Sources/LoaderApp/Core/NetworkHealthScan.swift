import Darwin
import Foundation
import LoaderCore
import LoaderShared

/// Detects — without root — network settings a previous Anemia session left in
/// a state that cannot work: a resolver pinned to a tunnel address no
/// interface holds anymore (no website resolves), or a SOCKS proxy on a
/// loopback port nothing listens on (browsers can't connect). Both survive
/// reboots, which is exactly how a stuck session used to look like a broken
/// Mac. Fixing them needs root: the helper's repair, or one admin prompt.
///
/// Same definitions as the helper's own sweep (``NetworkSettingsPolicy``), so
/// the app never flags something the repair would leave alone.
enum NetworkHealthScan {
    struct Issue: Equatable, Identifiable, Sendable {
        let id: String
        let message: String
    }

    /// A handful of `networksetup` reads — blocking, call off the main actor.
    static func scan() -> [Issue] {
        let live = liveIPv4Addresses()
        var issues: [Issue] = []
        for service in serviceNames() {
            if let out = networksetup(["-getdnsservers", service]) {
                let dns = NetworkSettingsPolicy.parseDNSServers(out)
                if NetworkSettingsPolicy.isDeadDNSPin(dns, liveIPv4: live, includeLegacy: true) {
                    issues.append(Issue(
                        id: "dns|\(service)",
                        message: "\(service): DNS is set to \(dns.joined(separator: ", ")) — a tunnel address that no longer exists, so no website can be resolved"))
                }
            }
            if let out = networksetup(["-getsocksfirewallproxy", service]),
               let proxy = NetworkSettingsPolicy.parseSocksProxy(out),
               NetworkSettingsPolicy.isDeadProxyPin(proxy, isPortLive: { PortFinder.canConnect($0) }) {
                issues.append(Issue(
                    id: "proxy|\(service)",
                    message: "\(service): SOCKS proxy \(proxy.host):\(proxy.port) is on, but nothing is listening there — browsers can't connect"))
            }
        }
        return issues
    }

    private static func serviceNames() -> [String] {
        guard let out = networksetup(["-listallnetworkservices"]) else { return [] }
        return parseServiceNames(out)
    }

    /// One header line, then one service per line; a disabled service carries
    /// a marker that is not part of its name (`* Wi-Fi`, and the ordered
    /// listing spells it `(*) Wi-Fi`). Trimming before dropping the marker was
    /// the bug: `* Wi-Fi` came back as " Wi-Fi", which `networksetup` refuses
    /// — measured here: `-getdnsservers " Wi-Fi"` exits 4 with "not a
    /// recognized network service", so both reads in `scan()` returned nil and
    /// the disabled service was skipped as cleanly as if it were healthy. The
    /// rule is the helper's own (`SystemCommand.parseNetworkServices`, which
    /// documents the same trap); this file promises "same definitions as the
    /// helper's own sweep".
    static func parseServiceNames(_ output: String) -> [String] {
        output.split(separator: "\n").dropFirst().compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            if line.hasPrefix("(*)") {
                line = String(line.dropFirst(3))
            } else if line.hasPrefix("*") {
                line = String(line.dropFirst())
            }
            line = line.trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? nil : line
        }
    }

    private static func networksetup(_ args: [String]) -> String? {
        guard let r = XrayController.runCapturing(
            binaryPath: "/usr/sbin/networksetup", arguments: args,
            qos: .utility, timeout: 5, mergeStderr: false),
              r.status == 0 else { return nil }
        return r.output
    }

    /// IPv4 addresses on every local interface (getifaddrs — no subprocess).
    static func liveIPv4Addresses() -> Set<String> {
        var result = Set<String>()
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return result }
        defer { freeifaddrs(head) }
        var cursor = head
        while let entry = cursor {
            if let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let bytes = buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                    result.insert(String(decoding: bytes, as: UTF8.self))
                }
            }
            cursor = entry.pointee.ifa_next
        }
        return result
    }
}
