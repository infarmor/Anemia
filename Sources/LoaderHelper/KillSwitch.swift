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
            // DHCP / router discovery so the physical link stays usable.
            "pass out quick inet proto udp from any to any port 67:68"
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
    /// if one was reported. The token is also persisted so that a helper
    /// restart (crash, launchd respawn) can release it — otherwise the kill
    /// switch would fail closed forever.
    @discardableResult
    static func enable(utun: String, serverV4: [String], serverV6: [String]) throws -> String? {
        let text = ruleset(utun: utun, serverV4: serverV4, serverV6: serverV6)
        let url = URL(fileURLWithPath: "/private/tmp/loader-killswitch.pf.conf")
        try text.write(to: url, atomically: true, encoding: .utf8)

        // -E enables pf (ref-counted, prints a token) and -f loads our rules.
        let r = SystemCommand.run("/sbin/pfctl", ["-E", "-f", url.path])
        // Token appears in output as: "Token : 1234567890"
        var token: String?
        for line in r.output.split(separator: "\n") {
            if line.contains("Token") {
                token = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
            }
        }
        if let token {
            try? token.write(toFile: Self.tokenFile, atomically: true, encoding: .utf8)
        }
        return token
    }

    /// Restore the system's default pf ruleset and release our enable reference.
    static func disable(token: String?) {
        restoreDefaultRuleset()
        if let token {
            SystemCommand.run("/sbin/pfctl", ["-X", token])
        } else {
            SystemCommand.run("/sbin/pfctl", ["-d"])
        }
        try? FileManager.default.removeItem(atPath: Self.tokenFile)
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
        SystemCommand.run("/sbin/pfctl", ["-X", token])
        try? FileManager.default.removeItem(atPath: Self.tokenFile)
    }

    /// Where the enable token is persisted between helper generations.
    private static var tokenFile: String { "/private/tmp/loader-killswitch.token" }

    /// Load the system's default ruleset, flushing ours. If /etc/pf.conf is
    /// absent (nonstandard setup), load an empty ruleset instead — either way
    /// our "block out all" rules are gone.
    private static func restoreDefaultRuleset() {
        let defaultConf = "/etc/pf.conf"
        let path = FileManager.default.fileExists(atPath: defaultConf) ? defaultConf : "/dev/null"
        SystemCommand.run("/sbin/pfctl", ["-f", path])
    }
}
