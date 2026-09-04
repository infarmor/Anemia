import Foundation

/// Well-known identifiers shared between the app and the privileged helper.
public enum LoaderIdentifiers {
    /// Mach service name the helper's XPC listener advertises. Must match the
    /// helper's launchd plist `MachServices` key and its code-sign identifier.
    public static let helperMachService = "com.loader.vpn.helper"
    /// Reverse-DNS bundle id of the helper tool.
    public static let helperBundleID = "com.loader.vpn.helper"
    /// Default local SOCKS inbound the tun bridge dials into.
    public static let defaultSocksPort = 10808
    public static let defaultHTTPPort = 10809
    /// utun addressing used by the tunnel (private, link-local-ish range).
    public static let defaultTunAddress = "198.18.0.1"
    public static let defaultTunGateway = "198.18.0.2"
    public static let defaultMTU = 1500
}

/// XPC contract implemented by the privileged helper and called by the app.
///
/// The helper runs as root and owns everything that needs elevated rights:
/// creating the utun interface, programming routes, and supervising the
/// tun2socks bridge that pumps packets into the local SOCKS inbound.
@objc public protocol LoaderHelperProtocol {
    /// Returns the helper's version string so the app can detect a stale
    /// installed helper and re-bless it.
    func getVersion(reply: @escaping (String) -> Void)

    /// Bring the system tunnel up: create utun, route traffic, start tun2socks
    /// forwarding to `socksHost:socksPort`. Reports success + optional error.
    ///
    /// `serverAddress` is the VPN server's host (domain or IP). The helper
    /// resolves it and pins a bypass route to it via the original gateway, so
    /// the engine's own encrypted connection to the server doesn't loop back
    /// into the tunnel.
    func startTunnel(
        socksHost: String,
        socksPort: Int,
        tunAddress: String,
        tunGateway: String,
        mtu: Int,
        serverAddress: String,
        killSwitch: Bool,
        reply: @escaping (Bool, String?) -> Void
    )

    /// Tear the tunnel down and restore the previous default route.
    func stopTunnel(reply: @escaping (Bool, String?) -> Void)

    /// Remove the helper (used by the app's uninstall flow).
    func uninstall(reply: @escaping (Bool) -> Void)
}

/// Helper version. Bump when the XPC contract or privileged behavior changes so
/// the app knows to reinstall.
public let LoaderHelperVersion = "0.1.0"
