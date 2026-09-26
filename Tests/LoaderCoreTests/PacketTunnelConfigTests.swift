import Foundation
import Testing
@testable import LoaderCore

/// The iOS engine shape: Xray's own tun inbound, in-process stats, a file
/// log, and the built-in Hysteria 2 client instead of the standalone bridge.
/// The macOS defaults must stay exactly as they were.
struct PacketTunnelConfigTests {

    private func tunnelBuilder() -> XrayConfigBuilder {
        var builder = XrayConfigBuilder(apiPort: nil, bufferSizeKB: 4)
        builder.inboundMode = .packetTunnel(mtu: 1500)
        builder.hysteriaMode = .native
        builder.collectsStats = true
        builder.dnsQueryStrategy = "UseIPv4"
        builder.logFile = "/tmp/anemia/engine.log"
        return builder
    }

    private func vless() -> ProxyServer {
        ProxyServer(name: "v", proto: .vless, address: "srv.example.com", port: 443,
                    credential: "uuid-1", network: .tcp, security: .reality,
                    sni: "www.microsoft.com", realityPublicKey: "PBK", realityShortId: "ab",
                    flow: "xtls-rprx-vision")
    }

    private func hysteria2(_ edit: (inout ProxyServer) -> Void = { _ in }) -> ProxyServer {
        var server = ProxyServer(name: "hy", proto: .hysteria2, address: "hy.example.com", port: 443,
                                 credential: "s3cret", sni: "cdn.example.com")
        server.userData = ["obfs": "salamander", "obfsPassword": "mask",
                           "pinSHA256": "ab:cd:ab:cd:ab:cd:ab:cd:ab:cd:ab:cd:ab:cd:ab:cd:ab:cd:ab:cd:ab:cd:ab:cd:ab:cd:ab:cd:ab:cd:ab:cd",   // 32 bytes in the OpenSSL spelling the engine accepts
                           "portHopping": "20000-50000"]
        edit(&server)
        return server
    }

    private func proxyOutbound(_ config: [String: Any]) throws -> [String: Any] {
        let outbounds = try #require(config["outbounds"] as? [[String: Any]])
        return try #require(outbounds.first { $0["tag"] as? String == "proxy" })
    }

    @Test func tunnelInboundReplacesTheLocalProxies() throws {
        let config = try tunnelBuilder().makeConfig(server: vless(), anti: .off)
        let inbounds = try #require(config["inbounds"] as? [[String: Any]])
        #expect(inbounds.count == 1)
        #expect(inbounds[0]["tag"] as? String == XrayConfigBuilder.tunnelInboundTag)
        #expect(inbounds[0]["protocol"] as? String == "tun")
        #expect((inbounds[0]["settings"] as? [String: Any])?["MTU"] as? Int == 1500)
        #expect((inbounds[0]["sniffing"] as? [String: Any])?["enabled"] as? Bool == true)
    }

    @Test func dnsHijackFollowsTheTunnelInbound() throws {
        let config = try tunnelBuilder().makeConfig(server: vless(), anti: .off)
        let rules = try #require((config["routing"] as? [String: Any])?["rules"] as? [[String: Any]])
        let hijack = try #require(rules.first { $0["outboundTag"] as? String == "dns-out" })
        #expect(hijack["inboundTag"] as? [String] == [XrayConfigBuilder.tunnelInboundTag])
        #expect((config["dns"] as? [String: Any])?["queryStrategy"] as? String == "UseIPv4")
    }

    @Test func statsAreCountedWithoutTheAPI() throws {
        let config = try tunnelBuilder().makeConfig(server: vless(), anti: .off)
        #expect(config["stats"] != nil)
        #expect(config["api"] == nil)
        let system = (config["policy"] as? [String: Any])?["system"] as? [String: Any]
        #expect(system?["statsOutboundUplink"] as? Bool == true)
        #expect(system?["statsOutboundDownlink"] as? Bool == true)
        let level0 = ((config["policy"] as? [String: Any])?["levels"] as? [String: Any])?["0"] as? [String: Any]
        #expect(level0?["bufferSize"] as? Int == 4)
    }

    @Test func errorsGoToTheLogFile() throws {
        let config = try tunnelBuilder().makeConfig(server: vless(), anti: .off)
        let log = try #require(config["log"] as? [String: Any])
        #expect(log["error"] as? String == "/tmp/anemia/engine.log")
        #expect(log["access"] as? String == "none")
    }

    @Test func nativeHysteriaOutbound() throws {
        let outbound = try proxyOutbound(tunnelBuilder().makeConfig(server: hysteria2(), anti: .recommended))
        #expect(outbound["protocol"] as? String == "hysteria")
        let settings = try #require(outbound["settings"] as? [String: Any])
        #expect(settings["version"] as? Int == 2)
        #expect(settings["address"] as? String == "hy.example.com")
        #expect(settings["port"] as? Int == 443)
        #expect(outbound["mux"] == nil)

        let stream = try #require(outbound["streamSettings"] as? [String: Any])
        #expect(stream["network"] as? String == "hysteria")
        #expect(stream["security"] as? String == "tls")
        #expect((stream["hysteriaSettings"] as? [String: Any])?["auth"] as? String == "s3cret")
        #expect((stream["hysteriaSettings"] as? [String: Any])?["version"] as? Int == 2)
        let tls = try #require(stream["tlsSettings"] as? [String: Any])
        #expect(tls["serverName"] as? String == "cdn.example.com")
        #expect(tls["pinnedPeerCertSha256"] as? String == "ab:cd:ab:cd:ab:cd:ab:cd:ab:cd:ab:cd:ab:cd:ab:cd:ab:cd:ab:cd:ab:cd:ab:cd:ab:cd:ab:cd:ab:cd:ab:cd")
        #expect(tls["fingerprint"] == nil)

        let finalmask = try #require(stream["finalmask"] as? [String: Any])
        let udp = try #require(finalmask["udp"] as? [[String: Any]])
        #expect(udp.first?["type"] as? String == "salamander")
        #expect((udp.first?["settings"] as? [String: Any])?["password"] as? String == "mask")
        let hop = (finalmask["quicParams"] as? [String: Any])?["udpHop"] as? [String: Any]
        // The link's own port joins the hop list when the range misses it.
        #expect(hop?["ports"] as? String == "443,20000-50000")
    }

    @Test func nativeHysteriaWithoutExtrasStaysPlain() throws {
        let plain = hysteria2 { $0.userData = nil }
        let stream = try #require(try proxyOutbound(tunnelBuilder().makeConfig(server: plain, anti: .off))["streamSettings"] as? [String: Any])
        #expect(stream["finalmask"] == nil)
        #expect((stream["tlsSettings"] as? [String: Any])?["pinnedPeerCertSha256"] == nil)
    }

    @Test func nativeHysteriaRefusesWhatXrayCannotRun() throws {
        #expect(throws: ConfigBuilderError.hysteriaV1Unsupported) {
            try tunnelBuilder().makeConfigData(server: hysteria2 { $0.proto = .hysteria }, anti: .off)
        }
        #expect(throws: ConfigBuilderError.hysteriaMissingAuth) {
            try tunnelBuilder().makeConfigData(server: hysteria2 { $0.credential = "" }, anti: .off)
        }
        #expect(throws: ConfigBuilderError.hysteriaInsecureWithoutPin) {
            try tunnelBuilder().makeConfigData(server: hysteria2 {
                $0.allowInsecure = true
                $0.userData?["pinSHA256"] = nil
            }, anti: .off)
        }
        // A pin makes an untrusted certificate acceptable.
        _ = try tunnelBuilder().makeConfigData(server: hysteria2 { $0.allowInsecure = true }, anti: .off)
        #expect(throws: ConfigBuilderError.hysteriaPinMalformed("zz3f")) {
            try tunnelBuilder().makeConfigData(server: hysteria2 {
                $0.userData?["pinSHA256"] = "zz3f"
            }, anti: .off)
        }
    }

    @Test func bypassNeedsNoPinInsideAPacketTunnel() throws {
        var builder = tunnelBuilder()
        builder.bypass = SplitTunnelParser.parse(["ru", "vk.com", "203.0.113.0/24"]).entries
        builder.bypassResolver = "77.88.8.8"
        let config = try builder.makeConfig(server: vless(), anti: .off)

        let outbounds = try #require(config["outbounds"] as? [[String: Any]])
        let bypass = try #require(outbounds.first { $0["tag"] as? String == "bypass" })
        #expect(bypass["protocol"] as? String == "freedom")
        #expect(bypass["streamSettings"] == nil, "no interface pin inside the provider")

        let rules = try #require((config["routing"] as? [String: Any])?["rules"] as? [[String: Any]])
        let bypassRules = rules.filter { $0["outboundTag"] as? String == "bypass" }
        #expect(bypassRules.contains { $0["domain"] as? [String] == ["domain:ru", "domain:vk.com"] })
        #expect(bypassRules.contains { $0["ip"] as? [String] == ["203.0.113.0/24"] })
        #expect(bypassRules.contains { $0["ip"] as? [String] == ["77.88.8.8/32"] })
        // Bypass rules sit ahead of the QUIC block.
        let firstBypass = try #require(rules.firstIndex { $0["outboundTag"] as? String == "bypass" })
        let quic = try #require(rules.firstIndex { $0["port"] as? Int == 443 })
        #expect(firstBypass < quic)

        let servers = try #require((config["dns"] as? [String: Any])?["servers"] as? [Any])
        let local = try #require(servers.first as? [String: Any])
        #expect(local["address"] as? String == "77.88.8.8")
        #expect(local["domains"] as? [String] == ["domain:ru", "domain:vk.com"])
        #expect(local["finalQuery"] as? Bool == true)
        #expect(local["skipFallback"] as? Bool == true)
        #expect(servers.dropFirst().compactMap { $0 as? String } == builder.remoteDNS)
    }

    @Test func bypassWithoutDomainsNeedsNoResolver() throws {
        var builder = tunnelBuilder()
        builder.bypass = SplitTunnelParser.parse(["10.20.0.0/16"]).entries
        builder.bypassResolver = "77.88.8.8"
        let config = try builder.makeConfig(server: vless(), anti: .off)
        let servers = try #require((config["dns"] as? [String: Any])?["servers"] as? [Any])
        #expect(servers.compactMap { $0 as? String } == builder.remoteDNS)
        #expect(servers.count == builder.remoteDNS.count)
        let rules = try #require((config["routing"] as? [String: Any])?["rules"] as? [[String: Any]])
        #expect(!rules.contains { ($0["ip"] as? [String]) == ["77.88.8.8/32"] })
    }

    @Test func macBypassStillRequiresThePin() throws {
        var unpinned = XrayConfigBuilder(apiPort: nil)
        unpinned.bypass = SplitTunnelParser.parse(["vk.com"]).entries
        unpinned.bypassResolver = "77.88.8.8"
        let config = try unpinned.makeConfig(server: vless(), anti: .off)
        let outbounds = try #require(config["outbounds"] as? [[String: Any]])
        #expect(!outbounds.contains { $0["tag"] as? String == "bypass" })
        #expect(((config["dns"] as? [String: Any])?["servers"] as? [Any])?.count == unpinned.remoteDNS.count)

        var pinned = XrayConfigBuilder(apiPort: nil, dialerInterface: "en0")
        pinned.bypass = SplitTunnelParser.parse(["vk.com"]).entries
        let pinnedConfig = try pinned.makeConfig(server: vless(), anti: .off)
        let bypass = try #require((pinnedConfig["outbounds"] as? [[String: Any]])?.first { $0["tag"] as? String == "bypass" })
        let sockopt = (bypass["streamSettings"] as? [String: Any])?["sockopt"] as? [String: Any]
        #expect(sockopt?["interface"] as? String == "en0")
    }

    @Test func macDefaultsAreUnchanged() throws {
        let builder = XrayConfigBuilder(apiPort: nil)
        let config = try builder.makeConfig(server: vless(), anti: .off)
        let inbounds = try #require(config["inbounds"] as? [[String: Any]])
        #expect(inbounds.map { $0["tag"] as? String } == ["socks-in", "http-in"])
        #expect(config["stats"] == nil)
        #expect((config["log"] as? [String: Any])?.keys.sorted() == ["loglevel"])
        #expect((config["dns"] as? [String: Any])?["queryStrategy"] as? String == "UseIP")
        let rules = try #require((config["routing"] as? [String: Any])?["rules"] as? [[String: Any]])
        let hijack = try #require(rules.first { $0["outboundTag"] as? String == "dns-out" })
        #expect(hijack["inboundTag"] as? [String] == ["socks-in", "http-in"])
        // Hysteria still goes through the standalone engine's SOCKS bridge.
        #expect(throws: ConfigBuilderError.hysteriaBridgeMissing) {
            try builder.makeConfig(server: hysteria2(), anti: .off)
        }
    }
}
