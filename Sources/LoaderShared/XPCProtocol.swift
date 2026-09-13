import Foundation

/// Well-known identifiers shared between the app and the privileged helper.
public enum LoaderIdentifiers {
    /// Mach service name the helper's XPC listener advertises. Must match the
    /// helper's launchd plist `MachServices` key and its code-sign identifier.
    public static let helperMachService = "com.loader.vpn.helper"
    /// Reverse-DNS bundle id of the helper tool.
    public static let helperBundleID = "com.loader.vpn.helper"
    /// Reverse-DNS bundle id of the app itself — the only XPC client the
    /// helper accepts (LOADER_CLIENT_REQUIREMENT checks the signed
    /// identifier on every connection).
    public static let appBundleID = "com.loader.vpn"
    /// Default local SOCKS inbound the tun bridge dials into.
    public static let defaultSocksPort = 10808
    public static let defaultHTTPPort = 10809
    /// utun addressing used by the tunnel. 172.28.0.0/24 (inside 172.16/12,
    /// which home LANs essentially never use) instead of the historical
    /// 198.18.0.0/24: that range is the fake-IP pool that sing-box/clash/
    /// mihomo VPN clients claim with a /16 address on their own TUN — the
    /// same 198.18.0.1 endpoint we used, which made tunnel DNS land in the
    /// foreign TUN and broke the tunnel whenever another VPN was connected.
    /// A range the fake-IP clients don't touch lets both run side by side.
    public static let defaultTunAddress = "172.28.0.1"
    public static let defaultTunGateway = "172.28.0.2"
    /// utun addressing for WireGuard-family sessions — a different /24 from
    /// the Xray tunnel's (172.28.0.0/24) so an xray session and an AWG
    /// session never share the collision gate's /24, and fake-IP clients
    /// (198.18/15) touch neither.
    public static let defaultAWGTunAddress = "172.29.0.1"
    public static let defaultAWGTunGateway = "172.29.0.2"
    /// Standard WireGuard MTU. AWG 3.1 configs usually carry MTU = 1280
    /// themselves (the wiki's recommendation) — a profile value overrides this.
    public static let defaultAWGMTU = 1420
    /// Userspace name the amneziawg-go daemon is asked to use; the UAPI socket
    /// path derives from it (/var/run/amneziawg/awg0.sock). The kernel still
    /// assigns the real utunN, which the helper detects after the spawn.
    public static let defaultAWGInterfaceName = "awg0"
    /// Tunnel MTU. 8500 (the hev-socks5-tunnel recommendation; sing-box/mihomo
    /// use 9000) instead of the physical-link-sized 1500: the utun feeds a
    /// *userspace* TCP stack that re-segments everything anyway, so a large MTU
    /// means fewer read/write syscalls per byte and measurably faster bulk
    /// throughput with no fragmentation on the real wire.
    public static let defaultMTU = 8500
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

    /// Coexist mode: point the macOS system SOCKS proxy at `host:port` (the
    /// engine's local SOCKS inbound) on every enabled network service, so
    /// proxy-aware apps (browsers) route through Anemia's foreign exit while a
    /// third-party whole-device VPN keeps handling the rest. Needs root
    /// (`networksetup`), hence the helper.
    func setSystemProxy(host: String, port: Int, reply: @escaping (Bool, String?) -> Void)

    /// Turn the system SOCKS proxy back off on every service we set it on.
    func clearSystemProxy(reply: @escaping (Bool, String?) -> Void)

    /// Point the macOS system DNS at `server` (the tunnel's gateway address)
    /// on every enabled network service, so system lookups are answered inside
    /// the tunnel by the engine (proxied DoH) instead of the ISP resolver —
    /// whose answers DPI poisons for blocked domains. Needs root
    /// (`networksetup`), hence the helper.
    func setSystemDNS(server: String, reply: @escaping (Bool, String?) -> Void)

    /// Restore automatic (DHCP-provided) DNS on every service we changed.
    func clearSystemDNS(reply: @escaping (Bool, String?) -> Void)

    /// Whether the tunnel is genuinely up right now (utun exists AND the
    /// tun2socks bridge process is alive). The app's health loop uses this to
    /// notice a dead bridge instead of displaying "Connected" forever.
    func tunnelStatus(reply: @escaping (Bool) -> Void)

    /// Remove the helper (used by the app's uninstall flow).
    func uninstall(reply: @escaping (Bool) -> Void)

    /// Bring up the system routing for an AmneziaWG / WireGuard session.
    ///
    /// Unlike ``startTunnel`` (which owns its own utun + tun2socks bridge),
    /// the WireGuard-family engine (`amneziawg-go`) is spawned HERE, as root:
    /// its UAPI unix socket lives under /var/run/amneziawg, which only root
    /// can create, so the non-root app can neither run the daemon nor push
    /// the config. Flow:
    ///   1. spawn `enginePath -f interfaceName`,
    ///   2. wait for `/var/run/amneziawg/<interfaceName>.sock`,
    ///   3. push `configScript` (the UAPI `set=1` payload built by
    ///      ``AmneziaWGConfigBuilder/makeUAPISetScript(server:)``) and require
    ///      `errno=0`,
    ///   4. detect the kernel-assigned utun the engine created,
    ///   5. address it `tunAddress`/`tunGateway`, install the split-default
    ///      /1 routes, pin the server bypass, arm the kill switch — the same
    ///      routing grammar as ``startTunnel``.
    ///
    /// `enginePath` comes from the client, which is cryptographically verified
    /// (see ``ClientVerifier``) — the same trust domain that already runs the
    /// user's own xray/tun2socks binaries. The helper still refuses paths
    /// that aren't executable regular files.
    ///
    /// On success the reply's message carries the kernel-assigned utun name
    /// (the engine picks it — the app never knows it otherwise).
    func startAWGTunnel(
        enginePath: String,
        interfaceName: String,
        configScript: String,
        tunAddress: String,
        tunGateway: String,
        mtu: Int,
        serverAddress: String,
        killSwitch: Bool,
        reply: @escaping (Bool, String?) -> Void
    )
}

/// Helper version. Bump when the XPC contract or privileged behavior changes so
/// the app knows to reinstall. 0.4.0 adds set/clearSystemProxy (coexist mode).
/// 0.5.0: physical-gateway fallback when a TUN owns the default route (third-
/// party VPN coexistence), stale-tunnel restart on startTunnel, unresolved
/// server hostname and ifconfig failures now fail loudly.
/// 0.6.0 adds set/clearSystemDNS (system resolver → tunnel, anti-DNS-poison)
/// and rejects XPC clients that aren't the genuine app (identifier check).
/// 0.6.1: IPv6 tunneled unconditionally (anti-leak when v6 gateway detection
/// fails on a v6-capable host), kill-switch arm failure now fails the connect.
/// 0.6.2: self-healing startTunnel (sweeps tun2socks orphaned by a dead helper
/// generation and the split routes it left — the cause of slow/failed connects
/// after a helper reinstall), split-default routes re-asserted on the 60 s
/// heartbeat and on network change (a third-party VPN client rewriting the
/// table no longer silently defangs the tunnel), SIGTERM kills the bridge so
/// the helper never leaks it.
/// 0.6.3: tunnel moved off the 198.18.0.0/15 fake-IP range (sing-box/clash/
/// mihomo claim it with a /16 on their own TUN — the same 198.18.0.1 endpoint
/// we used, which made tunnel DNS land in the foreign TUN and fake-IP answers
/// unroutable whenever another VPN was up). New addressing: 172.28.0.0/24,
/// which fake-IP clients don't touch, so Happ and Anemia coexist. The
/// collision gate stays: bringUp refuses if any interface already holds an
/// address in our /24, failing loudly into coexist mode instead of building
/// an ambiguous tunnel. Server-address resolution now rejects fake-IP
/// answers (a concurrently running sing-box/clash resolver replying from its
/// 198.18.0.0/15 pool — pinning a bypass route to a pool address blackholed
/// the engine) and falls back to direct DoH when getaddrinfo comes up empty
/// (mid-session reconnect with the resolver pointed at the restarting
/// tunnel). The engine's config now pins the server domain → IP into
/// dns.hosts, breaking the resolution loop that killed connections ~30 s
/// after connect (system resolver → tunnel → DoH through the proxy → needs
/// the server's own domain resolved → loop until TTL death).
/// 0.6.4 stability pass: bypass routes now re-pin via `route change` (a
/// network switch moves the physical gateway — bare `route add` left the old
/// dead next-hop in place), the 60 s heartbeat refreshes the gateways too,
/// and the kill switch allow-list re-arms when the server's re-resolution
/// discovers new IPs (a DNS rotation used to have pf drop the engine's dial
/// to the new address — tunnel dead mid-session, unrecoverable under the
/// kill switch). DoH gains a second upstream (8.8.8.8) behind 1.1.1.1, and
/// the app's health loop re-probes misses in 3 s so recovery starts at ~9 s
/// instead of ~30 s.
/// 0.7.0 adds startAWGTunnel: the helper spawns `amneziawg-go -f <iface>` as
/// root (its UAPI socket lives under /var/run/amneziawg, root-only), pushes
/// the client-built UAPI config, detects the engine's utun, and arms the
/// same routing/kill-switch/DNS grammar as startTunnel — full support for
/// AmneziaWG 1.0/1.5/2.0/3.0/3.1 and plain WireGuard endpoints.
public let LoaderHelperVersion = "0.7.0"
