import Foundation
import LoaderCore

/// Runs system tools (`ifconfig`, `route`, `tun2socks`) as root. The helper is
/// the only component allowed to do this.
enum SystemCommand {
    struct Result {
        let status: Int32
        let output: String
        var ok: Bool { status == 0 }
    }

    /// Run a command to completion and capture combined stdout/stderr.
    ///
    /// Bounded: the helper's serial state queue runs every XPC method, so a
    /// hung child used to wedge the whole daemon (including `stopTunnel`) with
    /// no recovery short of killing the process. On timeout the child is
    /// SIGTERMed (SIGKILL as fallback) and its partial output returned with a
    /// nonzero status — same contract as the app-side bounded shells.
    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 10) -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        let box = CommandOutputBox()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { box.append(chunk) }
        }
        do {
            try proc.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return Result(status: -1, output: "spawn failed: \(error.localizedDescription)")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if proc.isRunning {
            proc.terminate()
            let killDeadline = Date().addingTimeInterval(1)
            while proc.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            proc.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            // Drain anything written in the grace window, like the normal
            // path does — error messages from timed-out commands used to
            // come back truncated.
            box.append(pipe.fileHandleForReading.readDataToEndOfFile())
            return Result(status: proc.terminationStatus,
                          output: String(data: box.snapshot(), encoding: .utf8) ?? "")
        }
        proc.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        // Drain anything written between the last callback and EOF.
        box.append(pipe.fileHandleForReading.readDataToEndOfFile())
        return Result(status: proc.terminationStatus,
                      output: String(data: box.snapshot(), encoding: .utf8) ?? "")
    }

    // MARK: - Networking primitives

    /// Resolve a host to addresses of the given family (AF_INET / AF_INET6).
    static func resolve(_ host: String, family: Int32) -> [String] {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG, ai_family: family, ai_socktype: SOCK_STREAM,
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
                if !ips.contains(ip) { ips.append(ip) }
            }
            node = cur.pointee.ai_next
        }
        return ips
    }

    static func resolveIPv4(_ host: String) -> [String] { resolve(host, family: AF_INET) }
    static func resolveIPv6(_ host: String) -> [String] { resolve(host, family: AF_INET6) }

    /// Resolve over a direct DoH JSON query (Cloudflare then Google) — no
    /// system resolver involved. Used when getaddrinfo comes up empty,
    /// most often a mid-session reconnect where the system resolver is
    /// pointed at the restarting tunnel; the query leaves via whatever
    /// default route exists and returns genuine A records. Fake-IP answers
    /// (a concurrently running sing-box/clash client's resolver) are
    /// filtered so the bypass routes never pin a bogus pool address.
    static func resolveOverDoH(_ host: String) -> [String] {
        guard !DirectResolver.isIPv4(host), !DirectResolver.isFakeIP(host) else { return [] }
        for resolver in ["1.1.1.1", "8.8.8.8"] {
            // Percent-encode the host into the query string: a name carrying
            // `&`, `#` or whitespace (malformed client input) would otherwise
            // rewrite the query's semantics.
            let q = host.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? host
            let r = run("/usr/bin/curl", [
                "-s", "-m", "5", "--fail",
                "-H", "accept: application/dns-json",
                "https://\(resolver)/dns-query?name=\(q)&type=A"
            ])
            guard r.ok,
                  let data = r.output.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let answers = obj["Answer"] as? [[String: Any]]
            else { continue }
            let ips = answers.compactMap { ans -> String? in
                guard (ans["type"] as? Int) == 1, let ip = ans["data"] as? String,
                      // Only genuine dotted quads may enter the route table and
                      // the pf allow-list — a hostile resolver answer is text
                      // that root would otherwise interpolate into rulesets.
                      DirectResolver.isIPv4(ip), !DirectResolver.isFakeIP(ip) else { return nil }
                return ip
            }
            if !ips.isEmpty { return ips }
        }
        return []
    }

    /// The current default gateway for the given family (`-inet` / `-inet6`),
    /// resolved through the *physical* network.
    ///
    /// A TUN can hold the default route as a bare interface route (a
    /// third-party VPN client such as Happ/sing-box on 198.18.0.1, or our own
    /// tunnel during a reconnect race). `route -n get default` then reports
    /// `interface: utunN` with no `gateway:` line at all — the plain parse
    /// returned nil and the tunnel never came up ("No default gateway found"
    /// behind a "Connected" UI). So: use the route-get gateway only when the
    /// default route leaves through a physical interface; otherwise fall back
    /// to the physical default route from `netstat -rn`.
    static func defaultGateway(inet6: Bool = false) -> String? {
        let family = inet6 ? "-inet6" : "-inet"
        let r = run("/sbin/route", ["-n", "get", family, "default"])
        if r.ok {
            let parsed = parseRouteGet(r.output)
            if let gw = parsed.gateway, let iface = parsed.interface,
               !isTunnelInterface(iface) {
                return gw
            }
        }
        return netstatPhysicalGateway(inet6: inet6)
    }

    /// Parse `route -n get default` output into (gateway, interface). Either
    /// may be nil: when a TUN owns the default route (a third-party VPN such
    /// as Happ/sing-box, or our own tunnel during a reconnect race), the
    /// route is a bare interface route and there is no `gateway:` line at
    /// all — the historical cause of "No default gateway found" behind a
    /// "Connected" UI.
    static func parseRouteGet(_ output: String) -> (gateway: String?, interface: String?) {
        var gw: String?
        var iface: String?
        for line in output.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("gateway:") {
                gw = t.dropFirst("gateway:".count).trimmingCharacters(in: .whitespaces)
            } else if t.hasPrefix("interface:") {
                iface = t.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        // A link#N "gateway" is the bare interface route again — not a hop.
        if let g = gw, g.hasPrefix("link#") { gw = nil }
        return (gw, iface)
    }

    /// Physical default gateway from `netstat -rn -f inet|inet6`: the first
    /// `default <gw> … <iface>` row whose interface isn't a tunnel/loopback.
    private static func netstatPhysicalGateway(inet6: Bool) -> String? {
        let r = run("/usr/sbin/netstat", ["-rn", "-f", inet6 ? "inet6" : "inet"])
        guard r.ok else { return nil }
        return parseNetstatPhysicalGateway(r.output)
    }

    /// Parse `netstat -rn` output for the first physical default route.
    /// Row shape: `destination gateway flags refs use netif expire …` —
    /// fields[1] is the gateway, fields[3] the interface.
    static func parseNetstatPhysicalGateway(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.first == "default", fields.count >= 4 else { continue }
            let gateway = String(fields[1])
            let iface = String(fields[3])
            if !gateway.hasPrefix("link#"), !isTunnelInterface(iface) {
                return gateway
            }
        }
        return nil
    }

    /// Interfaces that carry tunneled or virtual traffic, not host traffic:
    /// TUNs, VPN PPP/IPsec, Apple's virtual proximity links, loopback.
    static func isTunnelInterface(_ name: String) -> Bool {
        name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp")
            || name.hasPrefix("awdl") || name.hasPrefix("llw") || name == "lo0"
    }

    /// Whether a network interface currently exists.
    static func interfaceExists(_ name: String) -> Bool {
        run("/sbin/ifconfig", [name]).ok
    }

    /// Pick a utun name that isn't currently in use. Nil when none is free —
    /// callers must refuse to build the tunnel rather than take over an
    /// interface they didn't verify (the old "utun99" fallback would happily
    /// address and route an interface already owned by another VPN client).
    static func freeUtunName() -> String? {
        for n in 90...199 where !interfaceExists("utun\(n)") {
            return "utun\(n)"
        }
        return nil
    }

    /// All IPv4 addresses each interface holds, parsed from `ifconfig -a`
    /// output: name → addresses. Used by the address-collision gate before
    /// the tunnel is built — a foreign interface already holding our
    /// endpoint's /24 (or the gateway host) makes source-address selection
    /// ambiguous and the tunnel half-broken.
    static func parseInetHolders(_ output: String) -> [String: [String]] {
        var holders: [String: [String]] = [:]
        var iface = ""
        for line in output.split(separator: "\n") {
            if !line.hasPrefix("\t"), let name = line.split(separator: ":", maxSplits: 1).first {
                iface = String(name)
                continue
            }
            // ifconfig indents address lines with a tab; split on any
            // whitespace so the first field is a clean "inet".
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // "inet 198.18.0.1 --> 198.18.0.1 netmask 0xffff0000"
            guard fields.count >= 2, fields[0] == "inet",
                  fields[1].split(separator: ".").count == 4
            else { continue }
            holders[iface, default: []].append(fields[1])
        }
        return holders
    }

    /// The first foreign address that collides with our tunnel addressing:
    /// inside the endpoint's /24 or equal to the gateway. Our own utun is
    /// created only after this check (and predecessors were swept), so any
    /// holder is foreign by construction.
    static func tunnelCollision(
        _ holders: [String: [String]], address: String, gateway: String
    ) -> (iface: String, ip: String)? {
        let prefix = address.split(separator: ".").prefix(3).joined(separator: ".")
        for (iface, ips) in holders.sorted(by: { $0.key < $1.key }) {
            for ip in ips where ip.hasPrefix(prefix + ".") || ip == gateway {
                return (iface, ip)
            }
        }
        return nil
    }

    /// Enabled network services (e.g. "Wi-Fi", "Ethernet") from
    /// `networksetup -listallnetworkservices`. The first line is a header, and
    /// a leading "*" marks a disabled service — both are skipped.
    static func enabledNetworkServices() -> [String] {
        let r = run("/usr/sbin/networksetup", ["-listallnetworkservices"])
        guard r.ok else { return [] }
        return r.output
            .split(separator: "\n")
            .dropFirst()                                   // header line
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") }  // "*" = disabled
    }

    /// Every network service, enabled or not (the "*" disabled marker stripped).
    static func allNetworkServices() -> [String] {
        let r = run("/usr/sbin/networksetup", ["-listallnetworkservices"])
        guard r.ok else { return [] }
        return r.output
            .split(separator: "\n")
            .dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("*") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty }
    }

    /// Drop cached name resolutions so a restored resolver takes effect for
    /// already-running apps immediately.
    static func flushDNSCache() {
        run("/usr/bin/dscacheutil", ["-flushcache"])
        run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }

    /// Path of the executable behind a pid, or nil if it can't be determined
    /// (process already gone, different user, system policy). Used to verify
    /// kill targets: `pgrep -f` matches the *full argument string*, so a
    /// `tail -f`/editor/grep referencing our install path would otherwise be
    /// caught in a root SIGTERM sweep.
    static func executablePath(pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 1024)   // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let bytes = buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Split-default rows (0/1, 128/1, ::/1, 8000::/1 — netstat prints both
    /// the short and long v4 forms) that point at a utun interface which no
    /// longer exists: the residue a crashed bridge leaves behind. Only these
    /// are safe to delete — a *live* foreign utun holding the same prefixes
    /// is a coexisting VPN client that must keep its routes.
    static func staleSplitRoutes() -> [(destination: String, inet6: Bool, iface: String)] {
        var rows: [(destination: String, inet6: Bool, iface: String)] = []
        for inet6 in [false, true] {
            let r = run("/usr/sbin/netstat", ["-rn", "-f", inet6 ? "inet6" : "inet"])
            guard r.ok else { continue }
            rows.append(contentsOf: parseStaleSplitRoutes(r.output, inet6: inet6))
        }
        return rows
    }

    /// Parse one `netstat -rn` family table for stale split-default rows.
    /// Row shape: `destination gateway flags refs use netif expire …`.
    /// `isDeadInterface` is injectable for tests (the production default
    /// shells out to ifconfig).
    static func parseStaleSplitRoutes(
        _ output: String, inet6: Bool,
        isDeadInterface: (String) -> Bool = { !SystemCommand.interfaceExists($0) }
    ) -> [(destination: String, inet6: Bool, iface: String)] {
        let v4Forms = ["0/1": "0.0.0.0/1", "0.0.0.0/1": "0.0.0.0/1",
                       "128/1": "128.0.0.0/1", "128.0.0.0/1": "128.0.0.0/1"]
        let v6Forms = ["::/1": "::/1", "8000::/1": "8000::/1"]
        var rows: [(destination: String, inet6: Bool, iface: String)] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4 else { continue }
            let dest = inet6 ? v6Forms[String(fields[0])] : v4Forms[String(fields[0])]
            let iface = String(fields[3])
            guard let dest, iface.hasPrefix("utun"), isDeadInterface(iface) else { continue }
            rows.append((destination: dest, inet6: inet6, iface: iface))
        }
        return rows
    }

    /// Make sure a `-net` route points at `interface`: `route change` first
    /// (moves an existing entry, e.g. one a coexisting VPN client re-added via
    /// its own utun), falling back to `route add` when there is nothing to
    /// change. A bare `add` on an existing entry fails with EEXIST and leaves
    /// the stale route in place — the re-assert would silently do nothing.
    ///
    /// Ownership guard: the entry is only *changed* when it currently leaves
    /// through a physical interface (the legitimate default route a VPN takes
    /// over — its original gateway entry survives and teardown restores it
    /// automatically) or through `interface` itself (already ours). An entry
    /// living on a *foreign* utun belongs to a coexisting VPN client
    /// (sing-box/clash auto_route): repointing it onto our utun would steal
    /// it, and our teardown's `route delete -interface <ours>` would then rip
    /// the foreign client's route out entirely until its next re-assert. In
    /// that case the change is refused with a clear message instead.
    @discardableResult
    static func ensureNetRoute(destination: String, interface: String, inet6: Bool) -> Result {
        let get = run("/sbin/route", routeGetArgs(destination: destination, inet6: inet6))
        if get.ok {
            let owner = parseRouteGet(get.output).interface
            // A route left on a utun that no longer exists (residue of a
            // crashed engine the sweep couldn't clear) belongs to nobody:
            // refusing it failed every reconnect with a bogus "another VPN"
            // error. Same liveness rule as the bring-up's ownership gate.
            if let owner, owner != interface, isTunnelInterface(owner), interfaceExists(owner) {
                return Result(status: 1, output: "refusing to steal \(destination) from \(owner) (owned by another tunnel)")
            }
        }
        var change = ["-n", "change"]
        if inet6 { change.append("-inet6") }
        change += ["-net", destination, "-interface", interface]
        let c = run("/sbin/route", change)
        if c.ok { return c }
        var add = ["-n", "add"]
        if inet6 { add.append("-inet6") }
        add += ["-net", destination, "-interface", interface]
        return run("/sbin/route", add)
    }

    /// `route -n get` argument list for a destination prefix (both the short
    /// and long v4 forms are accepted by `route`; the long form is used so
    /// the owner query matches what `ensureNetRoute` installs).
    private static func routeGetArgs(destination: String, inet6: Bool) -> [String] {
        var args = ["-n", "get"]
        if inet6 { args.append("-inet6") }
        args += ["-net", destination]
        return args
    }

    /// Host-route variant of ``ensureNetRoute`` for the server bypass pins.
    ///
    /// Add first; change only an entry that already exists. A `-host` change
    /// carries no netmask, and Darwin's RTM_CHANGE edits the longest-prefix
    /// match instead of failing — with no host route yet it rewrote the
    /// default (or our /1) route and exited 0, so the pin never existed and
    /// the engine's server dial had no path once the split routes were up.
    /// The result is read back so a pin that didn't take fails loudly.
    @discardableResult
    static func ensureHostRoute(host: String, gateway: String, inet6: Bool) -> Result {
        let family = inet6 ? ["-inet6"] : []
        var result = run("/sbin/route", ["-n", "add"] + family + ["-host", host, gateway])
        if !result.ok, result.output.contains("File exists") {
            result = run("/sbin/route", ["-n", "change"] + family + ["-host", host, gateway])
        }
        guard result.ok else { return result }
        let check = run("/sbin/route", ["-n", "get"] + family + [host])
        guard isHostRoutePinned(check.output, host: host, inet6: inet6) else {
            return Result(status: 1, output: "host route to \(host) did not take: \(check.output)")
        }
        return result
    }

    /// Whether `route -n get <host>` output shows an entry for exactly `host`
    /// leaving through a physical interface — not the best match of a
    /// covering route such as the default or a tunnel's /1.
    static func isHostRoutePinned(_ output: String, host: String, inet6: Bool) -> Bool {
        var destination: String?
        for line in output.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("destination:") {
                destination = t.dropFirst("destination:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let destination, sameAddress(destination, host, inet6: inet6),
              let iface = parseRouteGet(output).interface else { return false }
        return !isTunnelInterface(iface)
    }

    private static func sameAddress(_ a: String, _ b: String, inet6: Bool) -> Bool {
        guard inet6 else { return a == b }
        var x = in6_addr(), y = in6_addr()
        guard inet_pton(AF_INET6, a, &x) == 1, inet_pton(AF_INET6, b, &y) == 1 else { return false }
        return withUnsafeBytes(of: x) { xb in withUnsafeBytes(of: y) { yb in xb.elementsEqual(yb) } }
    }

    /// The interface name amneziawg-go writes to WG_TUN_NAME_FILE ("utun7\n"),
    /// or nil unless it is a kernel-assigned utunN — the name is spliced into
    /// the UAPI socket path.
    static func parseTunNameFile(_ contents: String) -> String? {
        let name = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count > 4, name.count <= 15, name.hasPrefix("utun"),
              name.dropFirst(4).allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return name
    }

    /// Network-route variant for split-tunnel destinations (change-then-add
    /// via a physical `gateway`).
    @discardableResult
    static func ensureGatewayRoute(destination: String, gateway: String, inet6: Bool) -> Result {
        var change = ["-n", "change"]
        if inet6 { change.append("-inet6") }
        change += ["-net", destination, gateway]
        let c = run("/sbin/route", change)
        if c.ok { return c }
        var add = ["-n", "add"]
        if inet6 { add.append("-inet6") }
        add += ["-net", destination, gateway]
        return run("/sbin/route", add)
    }

    /// Whether `destination` is reached over a directly connected physical
    /// link (no gateway, not a tunnel). Such a destination already stays off
    /// the tunnel — and repointing its link route at a gateway would cut the
    /// LAN (on macOS even an ARP entry answers as a host route).
    static func isDirectlyConnected(_ destination: String, network: Bool, inet6: Bool) -> Bool {
        var args = ["-n", "get"]
        if inet6 { args.append("-inet6") }
        args += [network ? "-net" : "-host", destination]
        let r = run("/sbin/route", args)
        guard r.ok else { return false }
        let parsed = parseRouteGet(r.output)
        guard let iface = parsed.interface, !isTunnelInterface(iface) else { return false }
        return parsed.gateway == nil
    }

    /// DNS servers currently configured on a service, as
    /// `networksetup -getdnsservers` prints them. Empty array = automatic
    /// (DHCP); a user's manual resolvers are preserved word for word so
    /// teardown can put back exactly what was there before we touched it.
    static func getDNSServers(service: String) -> [String]? {
        let r = run("/usr/sbin/networksetup", ["-getdnsservers", service])
        guard r.ok else { return nil }
        return parseDNSServers(r.output)
    }

    /// Parse `networksetup -getdnsservers` output. The "automatic (DHCP)"
    /// state is detected STRUCTURALLY, not by the English "There aren't any…"
    /// sentence: on a localized system that sentence used to be captured as a
    /// literal "server" and written back on restore, breaking DNS. An IP
    /// literal is locale-proof — a resolver line is kept only if it parses
    /// as dotted-quad or IPv6.
    static func parseDNSServers(_ output: String) -> [String] {
        output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && (DirectResolver.isIPv4($0) || $0.contains(":")) }
    }

    /// SOCKS proxy state currently configured on a service, as
    /// `networksetup -getsocksfirewallproxy` prints it — captured before we
    /// override it so teardown restores the user's own proxy (or none)
    /// instead of blindly switching the service off.
    static func getSocksProxy(service: String) -> (enabled: Bool, host: String, port: String)? {
        let r = run("/usr/sbin/networksetup", ["-getsocksfirewallproxy", service])
        guard r.ok else { return nil }
        return parseSocksProxy(r.output)
    }

    /// Parse `networksetup -getsocksfirewallproxy` output:
    /// "Enabled: Yes/No", "Server: host", "Port: number". Validated: an
    /// enabled state with no usable host/port is a MISREAD (localized
    /// output), not a capture — nil makes the caller leave that service
    /// untouched instead of restoring a broken "proxy: off" over the user's
    /// own configuration.
    static func parseSocksProxy(_ output: String) -> (enabled: Bool, host: String, port: String)? {
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
        // Validation applies only to the enabled state: "Enabled: No" prints
        // blank Server/Port fields — a valid, restorable "no proxy". An
        // ENABLED state with an empty host or a non-numeric port is a misread
        // (localized output), not a capture.
        if enabled, host.isEmpty || port.isEmpty || !port.allSatisfy(\.isNumber) {
            return nil
        }
        return (enabled, host, port)
    }
}

/// Thread-safe accumulator for subprocess output (readability callbacks arrive
/// on a private queue; the drain happens after waitUntilExit).
private final class CommandOutputBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
