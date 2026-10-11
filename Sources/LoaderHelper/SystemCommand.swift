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
        // Monotonic, not `Date()`: everything here is elapsed time, and the
        // wall clock moves. A step backwards used to make each bound
        // unbounded — on the helper's one serial queue, which is also the one
        // that answers `stopTunnel` — and a step forwards ended a healthy wait
        // at once. `SpeedTester` and `EngineProcess` were converted for the
        // same reason on the app side.
        let deadline = DispatchTime.now() + timeout
        while proc.isRunning && DispatchTime.now() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if proc.isRunning {
            proc.terminate()
            let killDeadline = DispatchTime.now() + 1
            while proc.isRunning && DispatchTime.now() < killDeadline {
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
        // Only a real next-hop counts. `route -n get` prints the *best match*,
        // and for an interface route the gateway line is not an address at all:
        // measured on a live tunnel here — `gateway: index: 25 utun90`. The old
        // `link#` special case caught one of the two shapes, so a default
        // leaving through a physical interface without a gateway handed this
        // string straight to `route add -host …`, and diagnostics printed
        // "via index: 25 utun90" as if it were an address.
        if let g = gw, !isGatewayAddress(g) { gw = nil }
        return (gw, iface)
    }

    /// Whether a parsed gateway column can be a next-hop for `route`: an
    /// address literal, and for IPv6 with its interface zone — measured on this
    /// Mac, `netstat -rn -f inet6` writes every link-local gateway as
    /// `fe80::%utunN`, and a link-local next-hop has to be written with that
    /// zone to be reachable. Two one-sided tests used to sit on either side of
    /// this: `route get` threw a real `fe80::%en0` away, and `netstat`'s row
    /// for an interface-scoped route (`default en0 … en0`, where the gateway
    /// column carries the interface *name*) came back as a gateway.
    static func isGatewayAddress(_ text: String) -> Bool {
        let address = String(text.prefix { $0 != "%" })
        return DirectResolver.isIPAddress(address)
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
            // `isGatewayAddress` also covers the old `link#N` marker: an
            // interface name in the gateway column is not an address either.
            if isGatewayAddress(gateway), !isTunnelInterface(iface) {
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
    /// a disabled service carries a leading marker — see
    /// ``parseNetworkServices``.
    static func enabledNetworkServices() -> [String] {
        let r = run("/usr/sbin/networksetup", ["-listallnetworkservices"])
        guard r.ok else { return [] }
        return parseNetworkServices(r.output).filter { $0.enabled }.map { $0.name }
    }

    /// Every network service, enabled or not, with the disabled marker
    /// stripped.
    static func allNetworkServices() -> [String] {
        let r = run("/usr/sbin/networksetup", ["-listallnetworkservices"])
        guard r.ok else { return [] }
        return parseNetworkServices(r.output).map { $0.name }
    }

    /// `networksetup -listallnetworkservices`: one header line, then one
    /// service per line, a disabled one carrying a leading marker (`* Wi-Fi`;
    /// the ordered variant of the same listing spells it `(*) Wi-Fi`, so both
    /// are tolerated). The marker is not part of the name. Trimming before
    /// dropping one character made `* Wi-Fi` come back as " Wi-Fi": a name no
    /// service matches, which in the restore path reads as "the user changed
    /// this one" and drops the ledger entry without putting anything back.
    static func parseNetworkServices(_ output: String) -> [(name: String, enabled: Bool)] {
        var services: [(name: String, enabled: Bool)] = []
        for raw in output.split(separator: "\n").dropFirst() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var enabled = true
            if line.hasPrefix("*") {
                enabled = false
                line = String(line.dropFirst())
            } else if line.hasPrefix("(*)") {
                enabled = false
                line = String(line.dropFirst(3))
            }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            services.append((line, enabled))
        }
        return services
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

    /// Whether `pid` still runs the executable launched at `launchPath` — the
    /// gate on the SIGKILL after a teardown grace, so getting it wrong means
    /// either a wedged engine that survives (the common half) or killing
    /// somebody else's recycled pid.
    ///
    /// Both sides have to be resolved before comparing: `proc_pidpath` answers
    /// with the path the kernel really used (`/tmp/…` comes back as
    /// `/private/tmp/…`, a brew symlink as its `Cellar/…` target — measured on
    /// this Mac while fixing the identical flaw app-side), while
    /// `Process.executableURL.path` is the launch path as the caller wrote it.
    /// The raw string compare that used to sit here was therefore false for
    /// every symlinked engine, and the kill rung simply never fired.
    static func pid(_ pid: pid_t, isExecutable launchPath: String) -> Bool {
        guard let live = executablePath(pid: pid) else { return false }
        return live == canonical(launchPath)
    }

    /// `realpath(3)` — the same resolution the kernel applies. Falls back to
    /// the input when the path cannot be resolved, which fails the comparison
    /// above rather than killing anything.
    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
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
        // "default" is in the table because a helper built before the
        // add-first fix left one there: change-first `ensureNetRoute` had
        // rewritten the machine's real default onto a utun, and its teardown
        // (`delete -net 0/1`) removed nothing — so the residue of a dead
        // tunnel was a default route into a device that no longer exists, i.e.
        // a machine with no way out. The same liveness rules below keep a
        // physical default (netif is not a utun) and a coexisting client's
        // live utun untouched.
        let v4Forms = ["0/1": "0.0.0.0/1", "0.0.0.0/1": "0.0.0.0/1",
                       "128/1": "128.0.0.0/1", "128.0.0.0/1": "128.0.0.0/1",
                       "default": "default"]
        let v6Forms = ["::/1": "::/1", "8000::/1": "8000::/1", "default": "default"]
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

    /// Make sure a `-net` route points at `interface`: `route add` first, and
    /// `route change` only when the entry really is there. Change-first was the
    /// bug: RTM_CHANGE edits the longest-prefix *match*, so with no 0/1 in the
    /// table yet it rewrote the machine's default route onto our utun and
    /// exited 0 — the add never ran, the /1 pair the whole design rests on never
    /// existed, and the comment's promise ("the legitimate default route a VPN
    /// takes over survives, teardown restores it") was quietly false: teardown's
    /// `delete -net 0/1` then removed nothing and left the default pointing at a
    /// dead utun. Same lesson `ensureHostRoute` records for `-host`.
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
        var add = ["-n", "add"]
        if inet6 { add.append("-inet6") }
        add += ["-net", destination, "-interface", interface]
        var result = run("/sbin/route", add)
        if !result.ok, result.output.contains("File exists") {
            var change = ["-n", "change"]
            if inet6 { change.append("-inet6") }
            change += ["-net", destination, "-interface", interface]
            result = run("/sbin/route", change)
        }
        return result
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
