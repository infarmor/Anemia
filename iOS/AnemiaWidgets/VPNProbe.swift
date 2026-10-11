import Darwin
import NetworkExtension

/// Whether Anemia's tunnel is up, as far as the widget extension can tell:
/// the VPN configuration when iOS shares it with the extension, otherwise
/// the tunnel interface itself.
enum VPNProbe {
    static func isOn() async -> Bool {
        await state().on
    }

    /// `on` — the tunnel is up or coming up; `connected` — it carries traffic.
    /// The widget needs both: with only `on` a VPN that came up on its own
    /// (on-demand after a reboot, before the app wrote a snapshot) read
    /// "Подключение…" forever.
    static func state() async -> (on: Bool, connected: Bool) {
        if let manager = try? await NETunnelProviderManager.loadAllFromPreferences().first {
            switch manager.connection.status {
            case .connected: return (true, true)
            case .connecting, .reasserting: return (true, false)
            default: return (false, false)
            }
        }
        let up = tunnelInterfaceUp()
        return (up, up)
    }

    /// A utun interface with an IPv4 address: the system's own utuns carry
    /// only IPv6 link-local ones.
    private static func tunnelInterfaceUp() -> Bool {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return false }
        defer { freeifaddrs(head) }
        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
                  String(cString: entry.pointee.ifa_name).hasPrefix("utun")
            else { continue }
            return true
        }
        return false
    }
}
