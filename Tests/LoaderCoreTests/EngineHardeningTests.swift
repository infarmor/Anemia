import Foundation
import Testing
@testable import LoaderCore

/// The server's domain → IP pin must reach the engine's own server dial.
/// Against the bundled 26.x engine, `dns.hosts` alone is ignored for that dial
/// (AsIs hands the domain to the system resolver); the socket that dials the
/// server has to carry `domainStrategy`. XrayEngineIntegrationTests drives
/// the real binary through the same shapes.
struct PinnedServerDialTests {
    private func realityServer(_ address: String = "edge.example.com") -> ProxyServer {
        ProxyServer(
            name: "P", proto: .vless, address: address, port: 443,
            credential: "uuid-1", network: .tcp, security: .reality,
            sni: "www.microsoft.com", fingerprint: "chrome",
            realityPublicKey: "PBK", realityShortId: "abcd", flow: "xtls-rprx-vision"
        )
    }

    private func outbound(_ cfg: [String: Any], _ tag: String) -> [String: Any]? {
        (cfg["outbounds"] as? [[String: Any]])?.first { $0["tag"] as? String == tag }
    }

    private func sockopt(_ outbound: [String: Any]?) -> [String: Any]? {
        (outbound?["streamSettings"] as? [String: Any])?["sockopt"] as? [String: Any]
    }

    @Test func pinnedDomainResolvesThroughEngineDNS() throws {
        var builder = XrayConfigBuilder()
        builder.dnsHosts = ["edge.example.com": "203.0.113.7"]
        let cfg = try builder.makeConfig(server: realityServer(), anti: .off)
        #expect(sockopt(outbound(cfg, "proxy"))?["domainStrategy"] as? String == "UseIPv4")
    }

    /// With fragmentation the fragment dialer owns the physical socket, so the
    /// strategy belongs there; the proxy only chains to it.
    @Test func pinFollowsTheFragmentDialer() throws {
        var builder = XrayConfigBuilder()
        builder.dnsHosts = ["edge.example.com": "203.0.113.7"]
        let cfg = try builder.makeConfig(server: realityServer(), anti: .recommended)
        #expect(sockopt(outbound(cfg, "fragment"))?["domainStrategy"] as? String == "UseIPv4")
        let proxy = sockopt(outbound(cfg, "proxy"))
        #expect(proxy?["dialerProxy"] as? String == "fragment")
        #expect(proxy?["domainStrategy"] == nil)
    }

    /// Without a pin the engine's DNS module would resolve the server via DoH
    /// through the very proxy it is trying to reach — keep AsIs.
    @Test func noPinKeepsTheSystemDial() throws {
        for anti in [AntiCensorshipOptions.off, .recommended] {
            let cfg = try XrayConfigBuilder().makeConfig(server: realityServer(), anti: anti)
            #expect(sockopt(outbound(cfg, "proxy"))?["domainStrategy"] == nil)
            #expect(sockopt(outbound(cfg, "fragment"))?["domainStrategy"] == nil)
        }
    }

    @Test func pinForAnotherNameDoesNotApply() throws {
        var builder = XrayConfigBuilder()
        builder.dnsHosts = ["other.example.com": "203.0.113.7"]
        let cfg = try builder.makeConfig(server: realityServer("198.51.100.4"), anti: .off)
        #expect(sockopt(outbound(cfg, "proxy"))?["domainStrategy"] == nil)
    }

    /// Hysteria traffic leaves through the local bridge; the (unused) fragment
    /// dialer must not start resolving the hysteria host through engine DNS.
    @Test func hysteriaBridgeIsNeverPinned() throws {
        var builder = XrayConfigBuilder()
        builder.dnsHosts = ["hy.example.com": "203.0.113.9"]
        let hy = ProxyServer(name: "H", proto: .hysteria2, address: "hy.example.com", port: 443,
                             credential: "pw", userData: ["hySocksPort": "20000"])
        let cfg = try builder.makeConfig(server: hy, anti: .recommended)
        #expect(sockopt(outbound(cfg, "fragment"))?["domainStrategy"] == nil)
    }

    @Test func dnsQueriesInParallelAndServesStale() throws {
        let cfg = try XrayConfigBuilder().makeConfig(server: realityServer(), anti: .off)
        let dns = try #require(cfg["dns"] as? [String: Any])
        #expect(dns["enableParallelQuery"] as? Bool == true)
        #expect(dns["serveStale"] as? Bool == true)
        #expect(dns["serveExpiredTTL"] as? Int == 3600)
        #expect(dns["disableCache"] as? Bool == false)
    }
}

struct AsyncRaceTests {
    @Test func firstSuccessWinsWithoutWaitingForSlowerOperations() async {
        let clock = ContinuousClock()
        let start = clock.now
        let operations: [@Sendable () async -> Int?] = [
            { try? await Task.sleep(for: .seconds(5)); return 1 },
            { try? await Task.sleep(for: .milliseconds(20)); return 2 }
        ]
        let result = await AsyncRace.firstNonNil(operations)
        #expect(result == 2)
        #expect(clock.now - start < .seconds(2), "the loser must be cancelled, not awaited")
    }

    @Test func aFastFailureDoesNotEndTheRace() async {
        let operations: [@Sendable () async -> Int?] = [
            { nil },
            { try? await Task.sleep(for: .milliseconds(30)); return 7 }
        ]
        #expect(await AsyncRace.firstNonNil(operations) == 7)
    }

    @Test func nilOnlyWhenEveryOperationFails() async {
        let operations: [@Sendable () async -> Int?] = [{ nil }, { nil }]
        #expect(await AsyncRace.firstNonNil(operations) == nil)
        #expect(await AsyncRace.firstNonNil([] as [@Sendable () async -> Int?]) == nil)
    }
}

/// Startup failures, as the bundled engine actually prints them.
struct EngineLogTests {
    @Test func configErrorSurfacesItsRootCause() {
        let line = #"Failed to start: main: failed to load config files: [/var/folders/x/T/loader-xray-1.json] > infra/conf: failed to build outbound config with tag  > infra/conf: failed to build stream settings for outbound detour > infra/conf: Failed to build TLS config. > common/errors: The feature "allowInsecure" has been removed and migrated to "pinnedPeerCertSha256". Please update your config(s) according to release note and documentation."#
        #expect(EngineLog.failureReason(from: ["Xray 26.3.27", line])
                == #"The feature "allowInsecure" has been removed and migrated to "pinnedPeerCertSha256". Please update your config(s) according to release note and documentation."#)
    }

    @Test func portConflictKeepsTheGoError() {
        let line = "Failed to start: app/proxyman/inbound: failed to listen TCP on 10808 > transport/internet: failed to listen on address: 127.0.0.1:10808 > transport/internet/tcp: failed to listen TCP on 127.0.0.1:10808 > listen tcp 127.0.0.1:10808: bind: address already in use"
        #expect(EngineLog.failureReason(from: [line]) == "listen tcp 127.0.0.1:10808: bind: address already in use")
    }

    @Test func fallbacks() {
        #expect(EngineLog.failureReason(from: ["Failed to start: boom"]) == "Failed to start: boom")
        #expect(EngineLog.failureReason(from: ["starting", "proxy/vless: failed to dial", "noise"])
                == "proxy/vless: failed to dial")
        #expect(EngineLog.failureReason(from: ["just a line"]) == "just a line")
        #expect(EngineLog.failureReason(from: []) == "engine exited during startup")
    }
}

// The cause returned by the engine, not read from its log — the Android shape of the
// same text. Pinned here as well as in `engine/cases.golden.txt`.
struct EngineCauseTests {
    @Test func chainWithoutTheCommandLineWrapper() {
        // `AnemiaStartXray` answers with what Go's error chain prints; xray's
        // own "Failed to start: " prefix exists only in the CLI's stderr.
        #expect(EngineLog.cause(from: "xray config: infra/conf: failed to build outbound config with tag proxy > infra/conf: unknown config id: nope")
                == "unknown config id: nope")
        #expect(EngineLog.cause(from: "app/proxyman/inbound: failed to listen TCP on 1 > transport/internet/tcp: failed to listen TCP on 127.0.0.1:1 > listen tcp 127.0.0.1:1: bind: permission denied")
                == "listen tcp 127.0.0.1:1: bind: permission denied")
        // Без цепочки — как пришла: обёртку снимать не с чего, а оставить
        // «Failed to start: boom» целиком честнее одного слова «boom».
        #expect(EngineLog.cause(from: "Failed to start: boom") == "Failed to start: boom")
        #expect(EngineLog.cause(from: "  a/b: one   >    c/d: two   ") == "two")
        #expect(EngineLog.cause(from: "a/b: one >  > c/d: two") == "two")
        #expect(EngineLog.cause(from: "   ") == "")
    }

    @Test func failureWordSearchIgnoresLocale() {
        #expect(EngineLog.looksLikeFailure("FAILED: app/proxyman: something"))
        #expect(EngineLog.looksLikeFailure("ОШИБКА: proxy/vless: failed to dial"))
        // Турецкая I:localized-складка Foundation перестала бы видеть здесь
        // «failed» на  устройстве с tr-локалью; ASCII-складка видит её одинаково
        // везде — и ровно поэтому «FAİLED» не отказ, а не «отказ» в одной локали.
        #expect(!EngineLog.looksLikeFailure("FAİLED: İ not I"))
        #expect(!EngineLog.looksLikeFailure("Xray 26.3.27 (Xray, Penetrates Everything.)"))
    }
}
