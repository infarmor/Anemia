import Foundation

/// Packet-filter (pf) based kill switch. When active, all egress is dropped
/// except: loopback, the tunnel interface, LAN, and the VPN server endpoints.
/// If the engine dies, pf keeps blocking — traffic fails closed, no leaks.
enum KillSwitch {

    /// Private LAN ranges allowed to stay reachable while the kill switch is on.
    private static let lanV4 = "{ 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 }"

    /// Build the pf ruleset text for the current tunnel.
    static func ruleset(utun: String, serverV4: [String], serverV6: [String]) -> String {
        var lines = [
            "set block-policy drop",
            "set skip on lo0",
            "block out all",
            "pass out quick on \(utun) all",
            "pass out quick inet from any to \(lanV4)",
            // DHCP / router discovery so the physical link stays usable. Tightened
            // to broadcast + LAN destinations only: an earlier "to any port
            // 67:68" let any monitored app exfiltrate to an arbitrary internet
            // host on those ports straight past the kill switch.
            "pass out quick inet proto udp from any to { 255.255.255.255 \(lanV4) } port 67",
            // ICMPv6 housekeeping (neighbor/router discovery + echo) — `block out
            // all` would otherwise strand IPv6 on the physical link for the
            // whole kill-switch session: with NDP replies blocked the host
            // can't re-learn its gateway after a link change, and v6 stays
            // dead even after the tunnel (and pf) goes away. These types carry
            // no data channel, so allowing them can't open an exfil path.
            "pass out quick inet6 proto icmp6 all icmp6-type { echoreq, neighbrsol, routersol }",
            // DHCPv6 client → multicast DHCPv6 servers (v6 lease renewal).
            "pass out quick inet6 proto udp from fe80::/10 to { ff02::1:2 } port 546"
        ]
        if !serverV4.isEmpty {
            lines.append("pass out quick inet from any to { \(serverV4.joined(separator: " ")) }")
        }
        if !serverV6.isEmpty {
            lines.append("pass out quick inet6 from any to { \(serverV6.joined(separator: " ")) }")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Enable pf with our ruleset. Returns the pf enable token (to release later)
    /// if one was reported. Throws when pf didn't actually arm — callers must
    /// not report a fail-closed state that isn't. The token is also persisted
    /// so that a helper restart (crash, launchd respawn) can release it —
    /// otherwise the kill switch would fail closed forever.
    ///
    /// Enable and load are separate pfctl calls: a combined `-E -f` that fails
    /// at the load step would leave pf enabled with a dangling reference and
    /// no token file — a leak `releaseStale` cannot repair. Here the token is
    /// persisted *before* the ruleset load, and a load failure immediately
    /// releases the reference again.
    @discardableResult
    static func enable(utun: String, serverV4: [String], serverV6: [String]) throws -> String? {
        let text = ruleset(utun: utun, serverV4: serverV4, serverV6: serverV6)
        try writeRuleset(text)

        // -E enables pf (ref-counted, prints a token).
        let e = SystemCommand.run("/sbin/pfctl", ["-E"])
        guard e.ok else { throw KillSwitchError.enableFailed(e.output) }
        // Token appears in output as: "Token : 1234567890". Match the digits
        // directly: a bare `split(separator: ":")` misparses localized or
        // reformatted output (e.g. "Token : 0 x 1234..." → "0 x 1234").
        var token: String?
        for line in e.output.split(separator: "\n") where line.contains("Token") {
            if let m = line.range(of: "[0-9]+", options: .regularExpression) {
                token = String(line[m])
            }
        }
        guard let token, !token.isEmpty else {
            // -E already raised pf's enable reference, but the token — the only
            // handle that can release it — never surfaced. `releaseStale` can't
            // help (nothing was persisted), so at minimum flush our rules back
            // to the system's default set before failing, so the reference
            // doesn't hold a "block out all" ruleset hostage.
            restoreDefaultRuleset()
            throw KillSwitchError.enableFailed("pfctl -E ran but printed no token")
        }
        try? token.write(toFile: Self.tokenFile, atomically: true, encoding: .utf8)

        let f = SystemCommand.run("/sbin/pfctl", ["-f", rulesetPath])
        guard f.ok else {
            // Fail closed in the other direction too: don't leave pf enabled
            // with no ruleset and no way to release the reference.
            disable(token: token)
            throw KillSwitchError.enableFailed(f.output)
        }
        return token
    }

    /// Re-load the ruleset with an updated server allow-list, keeping pf
    /// enabled and the token intact. Needed when the heartbeat's
    /// re-resolution discovers server IPs that weren't known at connect: a
    /// DNS rotation of the server domain means the new addresses fall
    /// through `block out all` — the tunnel dies mid-session with no
    /// recovery while the kill switch holds. On a load failure the previous
    /// (stale but stricter) ruleset stays active, so no throw: the safe
    /// direction is to keep blocking.
    static func rearm(utun: String, serverV4: [String], serverV6: [String]) {
        guard FileManager.default.fileExists(atPath: rulesetPath) else { return }
        let text = ruleset(utun: utun, serverV4: serverV4, serverV6: serverV6)
        try? writeRuleset(text)
        _ = SystemCommand.run("/sbin/pfctl", ["-f", rulesetPath])
    }

    /// Failure modes surfaced to the caller (and from it, to the app's UI).
    enum KillSwitchError: LocalizedError {
        case enableFailed(String)

        var errorDescription: String? {
            switch self {
            case .enableFailed(let detail):
                return "pfctl did not enable the ruleset: \(detail)"
            }
        }
    }

    /// Restore the system's default pf ruleset and release our enable reference.
    static func disable(token: String?) {
        // Reload the default ruleset rather than disabling pf entirely: a bare
        // `pfctl -d` would also switch off rules from other security tools
        // (e.g. Little Snitch / LuLu) that share the packet filter.
        restoreDefaultRuleset()
        if let token {
            let x = SystemCommand.run("/sbin/pfctl", ["-X", token])
            // Only forget the token when the release actually went through:
            // deleting it over a failed `-X` (corrupt token, pfctl hiccup)
            // would leave pf's reference count raised with no way to release
            // it — `releaseStale` after a restart finds no file and pf stays
            // enabled under a dangling reference forever.
            if x.ok {
                try? FileManager.default.removeItem(atPath: Self.tokenFile)
            }
        }
    }

    /// Startup recovery: if the helper died while the kill switch was armed, pf
    /// is still loaded with our block-everything rules and its enable token is
    /// lost. Release what the previous instance left behind so networking
    /// comes back after a crash/forced restart.
    static func releaseStale() {
        guard FileManager.default.fileExists(atPath: Self.tokenFile),
              let token = try? String(contentsOfFile: Self.tokenFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return }
        restoreDefaultRuleset()
        let x = SystemCommand.run("/sbin/pfctl", ["-X", token])
        // Same rule as disable(): keep the file if the release failed, so the
        // next attempt still has the token to try again with.
        if x.ok {
            try? FileManager.default.removeItem(atPath: Self.tokenFile)
        }
    }

    /// Where the enable token is persisted between helper generations.
    /// Root-owned state directory (created 0700), not /tmp: the token is a
    /// capability — anyone who can read it can disarm our pf reference.
    private static var stateDir: String { "/var/db/Loader" }
    private static var tokenFile: String { stateDir + "/killswitch.token" }
    private static var rulesetPath: String { stateDir + "/killswitch.pf.conf" }

    /// Write the ruleset into the root-only state directory (0700), so an
    /// unprivileged process can't swap rules that pfctl will load as root.
    private static func writeRuleset(_ text: String) throws {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        let url = URL(fileURLWithPath: rulesetPath)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rulesetPath)
    }

    /// Load the system's default ruleset, flushing ours. If /etc/pf.conf is
    /// absent (nonstandard setup), flush to an empty ruleset instead — either
    /// way our "block out all" rules are gone.
    private static func restoreDefaultRuleset() {
        let defaultConf = "/etc/pf.conf"
        if FileManager.default.fileExists(atPath: defaultConf) {
            SystemCommand.run("/sbin/pfctl", ["-f", defaultConf])
        } else {
            SystemCommand.run("/sbin/pfctl", ["-F", "all"])
        }
    }
}
