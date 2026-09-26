import Foundation

/// pf-based kill switch, confined to its own anchor.
///
/// While armed, all egress is dropped except loopback, the tunnel interface,
/// the LAN, link-local housekeeping and the VPN server endpoints. If the
/// engine dies, pf keeps blocking — traffic fails closed, no leaks.
///
/// The rules live in `com.apple/000.AnemiaKillSwitch`, an anchor the stock
/// `/etc/pf.conf` already evaluates through its `anchor "com.apple/*"` hook.
/// The main ruleset is never replaced: the earlier implementation loaded its
/// rules as the main ruleset and "disarmed" by reloading /etc/pf.conf, which
/// flushed the anchors other system services insert at runtime (Internet
/// Sharing, AirDrop) on every disconnect — and a crash left `block out all`
/// as the machine's only ruleset. Now disarming is flushing one anchor, and
/// every helper launch flushes it unconditionally, so no path can leave a
/// block behind that outlives the helper.
enum KillSwitch {

    static let anchor = "com.apple/000.AnemiaKillSwitch"

    /// Private ranges that stay reachable while armed (printers, NAS, router UI).
    private static let lanV4 = "10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16"

    enum KillSwitchError: LocalizedError {
        case armFailed(String)

        var errorDescription: String? {
            switch self {
            case .armFailed(let detail): return "pf did not arm the kill switch: \(detail)"
            }
        }
    }

    // MARK: - Ruleset

    /// The anchor's rules. Every rule is `quick` (the first match ends the
    /// whole evaluation, whatever other anchors follow) and stateless: `no
    /// state` makes a pass rule match mid-stream packets too, so connections
    /// that predate arming (the engine's own link to the server, a LAN SSH
    /// session) keep flowing, and a re-arm with new server addresses takes
    /// effect for every packet at once. Anchors can't carry `set` options, so
    /// loopback is passed explicitly instead of `set skip on lo0`.
    /// `serverV4` / `serverV6` are everything allowed out besides the tunnel:
    /// the server's addresses and split-tunnel hosts or networks (CIDR).
    static func ruleset(utun: String, serverV4: [String], serverV6: [String]) -> String {
        var lines = [
            "# Anemia kill switch — fail-closed egress (anchor \(anchor))",
            "pass out quick on lo0 all no state",
            "pass out quick on \(utun) all no state",
            // LAN, DHCP broadcast, link-local multicast (mDNS) and SSDP.
            "pass out quick inet from any to { \(lanV4) 224.0.0.0/24 239.255.255.250 255.255.255.255 } no state",
            // IPv6 link-local and link-scope multicast: neighbor discovery,
            // mDNS, DHCPv6. Not routable past the first hop, so no leak path.
            "pass out quick inet6 from any to { fe80::/10 ff02::/16 } no state",
            // Neighbor/router discovery to a neighbor's global address — with
            // these blocked the host can't re-learn its router after a link
            // change, and IPv6 stays dead after the kill switch is gone.
            "pass out quick inet6 proto icmp6 all icmp6-type { neighbrsol, neighbradv, routersol } no state"
        ]
        if !serverV4.isEmpty {
            lines.append("pass out quick inet from any to { \(serverV4.joined(separator: " ")) } no state")
        }
        if !serverV6.isEmpty {
            lines.append("pass out quick inet6 from any to { \(serverV6.joined(separator: " ")) } no state")
        }
        lines.append("block drop out quick all")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - pfctl output parsing (pure)

    /// `pfctl -E` prints "Token : 1234567890".
    static func parseEnableToken(_ output: String) -> String? {
        for line in output.split(separator: "\n") where line.contains("Token") {
            if let m = line.range(of: "[0-9]+", options: .regularExpression) {
                return String(line[m])
            }
        }
        return nil
    }

    /// `pfctl -s info` begins with "Status: Enabled for …" or "Status: Disabled".
    static func pfIsEnabled(_ info: String) -> Bool {
        info.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Status: Enabled") }
    }

    /// Whether the main ruleset (`pfctl -s rules`) still evaluates the
    /// com.apple anchors — without that hook our anchor is never consulted.
    static func hasAppleAnchorHook(_ mainRules: String) -> Bool {
        mainRules.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("anchor \"com.apple/*\"")
        }
    }

    // MARK: - Arm / re-arm / disarm (root)

    /// Load the anchor, make sure the main ruleset evaluates it, then take a
    /// pf enable reference. Returns the token to release on disarm. Throws
    /// when blocking isn't verifiably in force — a kill switch the user
    /// believes in but pf doesn't enforce is worse than none.
    static func arm(utun: String, serverV4: [String], serverV6: [String]) throws -> String {
        flush()
        try writeRuleset(ruleset(utun: utun, serverV4: serverV4, serverV6: serverV6))
        try loadAnchor()
        if !hasAppleAnchorHook(SystemCommand.run("/sbin/pfctl", ["-s", "rules"]).output) {
            // Someone replaced the main ruleset without Apple's hook (a pre-0.8
            // helper's leftover, or a third-party tool). Put the stock rules
            // back so the anchor is evaluated, then reload ours.
            repairMainRuleset()
            try loadAnchor()
            guard hasAppleAnchorHook(SystemCommand.run("/sbin/pfctl", ["-s", "rules"]).output) else {
                flush()
                throw KillSwitchError.armFailed("the main pf ruleset has no com.apple anchor hook")
            }
        }
        let e = SystemCommand.run("/sbin/pfctl", ["-E"])
        guard let token = parseEnableToken(e.output) else {
            flush()
            throw KillSwitchError.armFailed(e.ok ? "pfctl -E printed no token" : e.output)
        }
        guard pfIsEnabled(SystemCommand.run("/sbin/pfctl", ["-s", "info"]).output) else {
            release(token: token)
            throw KillSwitchError.armFailed("pf reports disabled after enable")
        }
        return token
    }

    /// Replace the anchor's rules with an updated server allow-list (a DNS
    /// rotation of the server's domain). The anchor load is atomic; on failure
    /// the previous, stricter ruleset stays in force — the safe direction.
    static func rearm(utun: String, serverV4: [String], serverV6: [String]) {
        guard (try? writeRuleset(ruleset(utun: utun, serverV4: serverV4, serverV6: serverV6))) != nil else { return }
        try? loadAnchor()
    }

    /// Flush our anchor, then drop the enable reference.
    static func disarm(token: String?) {
        flush()
        if let token { release(token: token) }
    }

    /// Remove every rule in our anchor. Scoped to the anchor — never `-F all`,
    /// whose state flush is global and would cut every tracked connection on
    /// the machine. Harmless when pf is off or the anchor is empty.
    static func flush() {
        SystemCommand.run("/sbin/pfctl", ["-a", anchor, "-F", "rules"])
    }

    static func release(token: String) {
        guard !token.isEmpty, token.allSatisfy(\.isNumber) else { return }
        SystemCommand.run("/sbin/pfctl", ["-X", token])
    }

    /// Recovery at helper launch and on repair: nothing from a previous
    /// generation may keep blocking. The anchor is flushed unconditionally
    /// (a crash between arming and recording the token leaves no token), the
    /// recorded reference is released, and a legacy main-ruleset kill switch
    /// gets the stock ruleset back.
    static func recover(token: String?, legacyMainRuleset: Bool) -> [String] {
        var report: [String] = []
        flush()
        if let token {
            release(token: token)
            report.append("pf: released kill-switch reference")
        }
        if legacyMainRuleset {
            repairMainRuleset()
            report.append("pf: restored the stock ruleset replaced by an older helper")
        }
        return report
    }

    /// Reload the stock main ruleset — only when it lacks Apple's hook: a
    /// reload flushes anchors other system services inserted at runtime.
    static func repairMainRuleset() {
        let conf = "/etc/pf.conf"
        guard let text = try? String(contentsOfFile: conf, encoding: .utf8),
              hasAppleAnchorHook(text) else { return }
        if !hasAppleAnchorHook(SystemCommand.run("/sbin/pfctl", ["-s", "rules"]).output) {
            SystemCommand.run("/sbin/pfctl", ["-f", conf])
        }
    }

    /// One-line pf summary for diagnostics.
    static func statusSummary() -> String {
        let enabled = pfIsEnabled(SystemCommand.run("/sbin/pfctl", ["-s", "info"]).output)
        let anchorRules = SystemCommand.run("/sbin/pfctl", ["-a", anchor, "-s", "rules"]).output
            .split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let hook = hasAppleAnchorHook(SystemCommand.run("/sbin/pfctl", ["-s", "rules"]).output)
        return "pf \(enabled ? "enabled" : "disabled"), kill-switch anchor \(anchorRules.isEmpty ? "empty" : "\(anchorRules.count) rules"), com.apple hook \(hook ? "present" : "MISSING")"
    }

    private static var rulesetPath: String { HelperPaths.stateDir + "/killswitch.anchor.conf" }

    private static func loadAnchor() throws {
        let r = SystemCommand.run("/sbin/pfctl", ["-a", anchor, "-f", rulesetPath])
        guard r.ok else { throw KillSwitchError.armFailed(r.output) }
    }

    /// Write the ruleset into the root-only state directory (0700).
    private static func writeRuleset(_ text: String) throws {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: HelperPaths.stateDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try text.write(to: URL(fileURLWithPath: rulesetPath), atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rulesetPath)
    }
}
