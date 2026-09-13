import Foundation

/// Detects the physical network interface, used to pin the engine's outbound
/// sockets (`sockopt.interface` → IP_BOUND_IF) so they always leave through
/// the real NIC — never through a TUN.
///
/// Why this matters: when any TUN holds the default route (our own tunnel
/// during a reconnect race, or a third-party VPN client such as a sing-box
/// app sitting on 198.18.0.1), an unpinned engine dial is swallowed by that
/// tunnel. The engine's fragmented ClientHello then loops into the VPN stack
/// instead of reaching the server: connection resets, dial errors, and —
/// with the loop feeding our own SOCKS inbound — an endless reconnect churn.
public enum PhysicalInterface {

    /// Best-effort name of the physical interface (e.g. "en0"). Prefers the
    /// owner of the current default route; if that is itself a tunnel,
    /// falls back to `scutil --nwi`, picking the first addressed interface
    /// that isn't a tunnel/point-to-point device. Nil when undetermined —
    /// callers then simply omit the pin rather than guessing.
    public static func primary() -> String? {
        if let viaRoute = defaultRouteInterface(), !isTunnel(viaRoute) {
            return viaRoute
        }
        return scutilPhysical()
    }

    /// Interfaces that forward other machines' packets, not host traffic:
    /// tunnels (utun), VPN PPP/IPsec, and Apple's virtual proximity links.
    private static func isTunnel(_ name: String) -> Bool {
        name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp")
            || name.hasPrefix("awdl") || name.hasPrefix("llw") || name == "lo0"
    }

    /// `route -n get default` → "interface: en0".
    private static func defaultRouteInterface() -> String? {
        guard let out = shell("/sbin/route", ["-n", "get", "default"]) else { return nil }
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: ":")
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "interface" {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Parse `scutil --nwi`: blocks like
    ///   "     en0 : flags ..(UP..) \n           address 192.168.0.103, .."
    /// First interface carrying an IPv4 address that isn't a tunnel wins.
    private static func scutilPhysical() -> String? {
        guard let out = shell("/usr/sbin/scutil", ["--nwi"]) else { return nil }
        var current: String?
        for raw in out.split(separator: "\n") {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Interface header lines look like "en0 : flags 0x…" (name before
            // " : flags"), indented under the "network interface information"
            // section; address lines carry "address <ip>".
            if let r = trimmed.range(of: " : flags") {
                let name = String(trimmed[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                current = name.isEmpty ? nil : name
            } else if trimmed.hasPrefix("address ") || trimmed.contains(" address ") {
                // Only an IPv4 address counts: the engine's server addresses
                // are dialed over v4 first, and an interface whose only
                // address is IPv6 (or a v6 link-local) can't carry an
                // IP_BOUND_IF-pinned v4 dial — pinning to it would break the
                // connect for no gain. scutil lists v4 and v6 addresses
                // alike, so they must be told apart here.
                let ip = trimmed.split(separator: " ").last.map(String.init) ?? ""
                let isIPv4 = ip.contains(".") && !ip.contains(":")
                guard isIPv4 else { continue } // v6 line — keep scanning for the v4 one
                if let name = current, !isTunnel(name) {
                    return name
                }
                current = nil // addressed tunnel — consumed, keep scanning
            }
        }
        return nil
    }

    /// Bounded shell-out: `readDataToEndOfFile()` used to block forever on a
    /// hung child (route/scutil are reliable but not guaranteed), and this runs
    /// inside the connect path — a wedged child stalled the whole connect. On
    /// timeout the child is terminated and nil returned; the caller just omits
    /// the interface pin.
    private static func shell(_ path: String, _ args: [String], timeout: TimeInterval = 2) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        let box = ShellOutputBox()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { box.append(chunk) }
        }
        do { try proc.run() } catch { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        if proc.isRunning {
            proc.terminate()
            let killDeadline = Date().addingTimeInterval(0.5)
            while proc.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            proc.waitUntilExit()
            return nil
        }
        proc.waitUntilExit()
        // Drain anything written between the last callback and EOF.
        box.append(pipe.fileHandleForReading.readDataToEndOfFile())
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: box.snapshot(), encoding: .utf8)
    }
}

/// Thread-safe accumulator: readability callbacks arrive on a private queue,
/// the drain happens after waitUntilExit.
private final class ShellOutputBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
