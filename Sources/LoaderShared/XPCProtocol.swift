import Foundation
import LoaderCore

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
    /// (198.18/15) touch neither. One value with the iOS tunnel, which falls
    /// back to it the same way when a profile names no IPv4 Address.
    public static let defaultAWGTunAddress = AmneziaWGConfigBuilder.fallbackTunAddress
    public static let defaultAWGTunGateway = "172.29.0.2"
    /// Standard WireGuard MTU. AWG 3.1 configs usually carry MTU = 1280
    /// themselves (the wiki's recommendation) — a profile value overrides this.
    public static let defaultAWGMTU = 1420
    /// Interface name the amneziawg-go daemon is asked for. macOS creates TUN
    /// devices named utunN only — the engine refuses any other name — so
    /// "utun" lets the kernel pick; the engine reports the name it got (and
    /// names its UAPI socket after it) through WG_TUN_NAME_FILE.
    public static let defaultAWGInterfaceName = "utun"
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
    ///   1. spawn `enginePath -f utun` (macOS names TUN devices utunN only;
    ///      `interfaceName` stays in the contract but is ignored, ≥ 0.9.2),
    ///   2. read the kernel-assigned utunN from WG_TUN_NAME_FILE and wait for
    ///      `/var/run/amneziawg/<utunN>.sock` to accept connections,
    ///   3. push `configScript` (the UAPI `set=1` payload built by
    ///      ``AmneziaWGConfigBuilder/makeUAPISetScript(server:)``) and require
    ///      `errno=0`,
    ///   4. confirm the engine's utun exists,
    ///   5. address it `tunAddress`/`tunGateway`, install the split-default
    ///      /1 routes, pin the server bypass, arm the kill switch — the same
    ///      routing grammar as ``startTunnel``.
    ///
    /// `enginePath` names the binary, but the helper only runs one that only
    /// root can change (see ``EngineBinaryPolicy``): the installed
    /// `/Library/PrivilegedHelperTools/amneziawg-go` — root-owned, not
    /// group/world-writable, not a symlink. Anything else is refused with the
    /// reason in the reply (≥ 0.9.0).
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

    /// Undo everything a session — or a crashed helper generation — could have
    /// left on the system: tear down any tunnel, restore recorded DNS/proxy
    /// overrides, flush the kill switch, kill orphaned bridges, drop dead
    /// routes, reset resolvers and loopback proxies that can't work. Replies
    /// with a human-readable report of what was changed. Requires helper ≥ 0.8.0.
    func repairNetwork(reply: @escaping (Bool, String) -> Void)

    /// Human-readable snapshot of everything the helper can change on the
    /// system (tunnel, pf, recorded overrides, routes). Requires helper ≥ 0.8.0.
    func networkDiagnostics(reply: @escaping (String) -> Void)

    /// Split tunneling for the live tunnel (≥ 0.8.0): route `networks`
    /// (IPv4/IPv6 CIDRs) and the current addresses of `domains` via the
    /// physical gateway instead of the utun, keep them open under the kill
    /// switch, and re-resolve the domains with the server. Replaces any
    /// previous list; empty lists clear it. Entries are re-validated here.
    func applyBypass(networks: [String], domains: [String], reply: @escaping (Bool, String?) -> Void)
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
/// 0.8.0 network-safety rework: every persistent change (DNS, SOCKS proxy, pf
/// reference) goes through a fsync'd journal written before the change and
/// replayed at every launch; leftover pins are never captured as the user's
/// settings; VPN services are never touched; the kill switch lives in its own
/// pf anchor instead of replacing the main ruleset; SIGTERM tears everything
/// down gracefully; a crashed helper is respawned by launchd and recovers;
/// adds repairNetwork / networkDiagnostics and the `--restore-network` CLI.
/// 0.9.0 runs only a root-owned, allow-listed AmneziaWG engine (the installer
/// places amneziawg-go next to the helper) — a client-named binary under the
/// user's control is no longer executed as root.
/// 0.9.1: clients are re-verified on every message by audit token (no
/// pid-reuse window); a route left on a dead utun no longer blocks bring-up as
/// "another VPN"; orphaned engines are killed before the stale-route sweep;
/// the SOCKS upstream must be loopback; uninstall removes the AmneziaWG engine.
/// 0.9.2: server bypass host routes are added first and read back — the
/// `route change -host` used since 0.6.4 edits the longest-prefix route on
/// Darwin and never created the pin, so the engine's server dial had no path
/// once the /1 split routes were up (every full-tunnel session died within
/// seconds). AmneziaWG asks the kernel for a `utun` (macOS refuses any other
/// name) and finds its UAPI socket through WG_TUN_NAME_FILE.
public let LoaderHelperVersion = "0.9.2"
