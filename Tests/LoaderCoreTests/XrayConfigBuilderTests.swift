import Foundation
import Testing
@testable import LoaderCore

struct XrayConfigBuilderTests {

    private func realityServer() -> ProxyServer {
        ProxyServer(
            name: "R", proto: .vless, address: "example.com", port: 443,
            credential: "uuid-1", network: .tcp, security: .reality,
            sni: "www.microsoft.com", fingerprint: "chrome",
            realityPublicKey: "PBK", realityShortId: "abcd", flow: "xtls-rprx-vision"
        )
    }

    @Test func testInboundsPresent() throws {
        let builder = XrayConfigBuilder(socksPort: 10808, httpPort: 10809, apiPort: nil)
        let cfg = try builder.makeConfig(server: realityServer(), anti: .off)
        let inbounds = cfg["inbounds"] as! [[String: Any]]
        #expect(inbounds.count == 2)   // no api inbound when apiPort == nil
        #expect(inbounds[0]["port"] as? Int == 10808)
        #expect(inbounds[1]["port"] as? Int == 10809)
    }

    /// Regression: the fold into `Int` used to keep the sign bit, and Swift's
    /// `%` keeps the dividend's sign — the mimicry pick
    /// `mimicry[stableHash(id) % count]` then built a negative index and
    /// crashed the whole config builder (Index out of range) for any server
    /// whose identity hashed sign-bit-set. The hash must stay non-negative so
    /// the modulo is always in-bounds.
    @Test func testStableHashNeverNegative() throws {
        var keys = ["", "a", "example.com", "e.com|vless|tcp|443|uuid-1", "🇩🇪 DE-01"]
        for i in 0..<2000 { keys.append("node-\(i)@panel-\(i % 7).example") }
        for k in keys {
            #expect(XrayConfigBuilder.stableHash(k) >= 0, "negative stableHash crashes the mimicry pick for key \(k)")
        }
        // And the actual use site: a mimicry pick over a RU preset must build
        // a config for ANY identity, including formerly-crashing ones.
        let anti = AntiCensorshipOptions.russiaYandex
        for k in keys {
            let server = ProxyServer(name: k, proto: .trojan, address: "real.example.com",
                                     port: 443, credential: "p", network: .tcp, security: .tls)
            #expect(throws: Never.self) { try XrayConfigBuilder().makeConfigData(server: server, anti: anti) }
        }
    }

    @Test func testStatsApiInboundAndPolicy() throws {
        let cfg = try XrayConfigBuilder(apiPort: 10812).makeConfig(server: realityServer(), anti: .off)
        let inbounds = cfg["inbounds"] as! [[String: Any]]
        #expect(inbounds.contains { $0["tag"] as? String == "api-in" })
        #expect((cfg["api"] as? [String: Any])?["tag"] as? String == "api")
        #expect(cfg["stats"] != nil)
        #expect(cfg["policy"] != nil)
        #expect(cfg["dns"] != nil)   // anti-leak DNS always present
    }

    /// The connection-tuning policy (buffer/idle/handshake) is always present —
    /// even without the stats API — and the stats system-policy is merged in,
    /// not overwritten, when the API is enabled. `bufferSizeKB` is honoured.
    @Test func testConnectionPolicyTuning() throws {
        // No API: level-0 tuning still present, no stats system policy.
        let noApi = try XrayConfigBuilder(apiPort: nil, bufferSizeKB: 768)
            .makeConfig(server: realityServer(), anti: .off)
        let p0 = noApi["policy"] as? [String: Any]
        let level0 = ((p0?["levels"] as? [String: Any])?["0"]) as? [String: Any]
        #expect(level0?["bufferSize"] as? Int == 768)
        #expect(level0?["connIdle"] as? Int == 300)
        #expect(level0?["handshake"] as? Int == 4)
        #expect(p0?["system"] == nil, "no stats system policy without the API")

        // With API: tuning kept AND stats system policy merged in.
        let withApi = try XrayConfigBuilder(apiPort: 10812).makeConfig(server: realityServer(), anti: .off)
        let p1 = withApi["policy"] as? [String: Any]
        #expect(((p1?["levels"] as? [String: Any])?["0"]) as? [String: Any] != nil)
        #expect((p1?["system"] as? [String: Any])?["statsOutboundUplink"] as? Bool == true)
    }

    /// QUIC (UDP/443) is routed to the block outbound by default so browsers
    /// fall back to TCP; disabling `blockQUIC` removes the rule. DNS caching is
    /// explicit.
    @Test func testBlockQUICAndDNSCache() throws {
        func quicRule(_ cfg: [String: Any]) -> [String: Any]? {
            let rules = (cfg["routing"] as! [String: Any])["rules"] as! [[String: Any]]
            return rules.first { ($0["network"] as? String) == "udp" && ($0["port"] as? Int) == 443 }
        }
        let on = try XrayConfigBuilder().makeConfig(server: realityServer(), anti: .off)
        let rule = quicRule(on)
        #expect(rule?["outboundTag"] as? String == "block")
        #expect((on["dns"] as? [String: Any])?["disableCache"] as? Bool == false)

        let off = try XrayConfigBuilder(blockQUIC: false).makeConfig(server: realityServer(), anti: .off)
        #expect(quicRule(off) == nil, "no QUIC block rule when disabled")
    }

    @Test func testRealityOutbound() throws {
        let cfg = try XrayConfigBuilder().makeConfig(server: realityServer(), anti: .off)
        let outbounds = cfg["outbounds"] as! [[String: Any]]
        let proxy = outbounds.first { $0["tag"] as? String == "proxy" }!
        let stream = proxy["streamSettings"] as! [String: Any]
        #expect(stream["security"] as? String == "reality")
        let reality = stream["realitySettings"] as! [String: Any]
        #expect(reality["publicKey"] as? String == "PBK")
        #expect(reality["serverName"] as? String == "www.microsoft.com")

        // Vision flow present on user.
        let settings = proxy["settings"] as! [String: Any]
        let vnext = settings["vnext"] as! [[String: Any]]
        let users = vnext[0]["users"] as! [[String: Any]]
        #expect(users[0]["flow"] as? String == "xtls-rprx-vision")
    }

    @Test func testFragmentAndNoiseInjected() throws {
        let cfg = try XrayConfigBuilder().makeConfig(server: realityServer(), anti: .recommended)
        let outbounds = cfg["outbounds"] as! [[String: Any]]

        // Fragment outbound exists and carries junk noises (TFO is — by
        // design, Xray-core#989 — never emitted on Darwin).
        let fragment = outbounds.first { $0["tag"] as? String == "fragment" }
        #expect(fragment != nil, "fragment dialer outbound should be present")
        let fragStream = fragment!["streamSettings"] as! [String: Any]
        let fragSockopt = fragStream["sockopt"] as! [String: Any]
        #expect(fragSockopt["tcpFastOpen"] == nil, "TFO is EINVAL-fatal on Darwin — never emit it")
        #expect(fragSockopt["tcpNoDelay"] as? Bool == true)
        #expect(fragSockopt["noises"] != nil, "junk noises should be present")

        // Proxy chains into the fragment dialer.
        let proxy = outbounds.first { $0["tag"] as? String == "proxy" }!
        let proxyStream = proxy["streamSettings"] as! [String: Any]
        let proxySockopt = proxyStream["sockopt"] as! [String: Any]
        #expect(proxySockopt["dialerProxy"] as? String == "fragment")
    }

    @Test func testVisionDisablesMux() throws {
        var anti = AntiCensorshipOptions.recommended
        anti.muxEnabled = true
        let cfg = try XrayConfigBuilder().makeConfig(server: realityServer(), anti: anti)
        let outbounds = cfg["outbounds"] as! [[String: Any]]
        let proxy = outbounds.first { $0["tag"] as? String == "proxy" }!
        #expect(proxy["mux"] == nil, "mux must be disabled under XTLS-Vision")
    }

    @Test func testShadowsocksOutbound() throws {
        let s = ProxyServer(name: "S", proto: .shadowsocks, address: "ss.example.com", port: 8388,
                            credential: "pw", method: "aes-256-gcm")
        let cfg = try XrayConfigBuilder().makeConfig(server: s, anti: .off)
        let outbounds = cfg["outbounds"] as! [[String: Any]]
        let proxy = outbounds.first { $0["tag"] as? String == "proxy" }!
        #expect(proxy["protocol"] as? String == "shadowsocks")
        let servers = (proxy["settings"] as! [String: Any])["servers"] as! [[String: Any]]
        #expect(servers[0]["method"] as? String == "aes-256-gcm")
    }

    @Test func testSerializesToValidJSON() throws {
        let data = try XrayConfigBuilder().makeConfigData(server: realityServer(), anti: .recommended)
        let roundtrip = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(roundtrip?["outbounds"] != nil)
    }

    /// HTTP/2 and QUIC stream transports were removed from the engine in
    /// 26.x — building a config for them must fail with a clear error, not
    /// produce something the engine rejects with a cryptic core message.
    @Test func testRemovedTransportsRejectedAtBuild() throws {
        for network in [NetworkType.http, .quic] {
            var server = realityServer()
            server.network = network
            if let err = #expect(throws: (any Error).self, performing: { try XrayConfigBuilder().makeConfigData(server: server, anti: .off) }) {
                #expect(err as? ConfigBuilderError == .transportRemovedByEngine(network.rawValue))
            }
        }
    }

    /// gRPC `mode=multi` and the `:authority` from the link must survive into
    /// grpcSettings — dropping them silently broke servers that need them.
    @Test func testGRPCSettingsCarryModeAndAuthority() throws {
        var server = realityServer()
        server.network = .grpc
        server.path = "GunSvc"
        server.host = "front.example.com"
        server.grpcMultiMode = true
        let cfg = try XrayConfigBuilder().makeConfig(server: server, anti: .off)
        let proxy = (cfg["outbounds"] as! [[String: Any]]).first { $0["tag"] as? String == "proxy" }!
        let grpc = ((proxy["streamSettings"] as! [String: Any])["grpcSettings"]) as! [String: Any]
        #expect(grpc["serviceName"] as? String == "GunSvc")
        #expect(grpc["authority"] as? String == "front.example.com")
        #expect(grpc["multiMode"] as? Bool == true)
    }

    @Test func testGRPCOmitsMultiModeByDefault() throws {
        var server = realityServer()
        server.network = .grpc
        server.path = "GunSvc"
        let cfg = try XrayConfigBuilder().makeConfig(server: server, anti: .off)
        let proxy = (cfg["outbounds"] as! [[String: Any]]).first { $0["tag"] as? String == "proxy" }!
        let grpc = ((proxy["streamSettings"] as! [String: Any])["grpcSettings"]) as! [String: Any]
        #expect(grpc["multiMode"] == nil)
        #expect(grpc["authority"] == nil)
    }

    /// 26.x removed mKCP `seed` and `header` obfuscation: the engine answers
    /// `removed feature: mkcp header & seed` if they are emitted, and dialing
    /// plain mKCP at a server that expects them is worse — no answer, no
    /// error. So such a server must be refused here, by name.
    @Test func testMKCPObfuscationIsRefused() throws {
        var server = realityServer()
        server.network = .kcp
        server.security = .tls
        server.path = "/mkcp"            // legacy links parked a seed here
        server.headerType = "srtp"
        #expect(throws: ConfigBuilderError.mkcpObfuscationUnsupported("header=srtp")) {
            _ = try XrayConfigBuilder().makeConfig(server: server, anti: .off)
        }
        server.userData = ["kcpSeed": "seed-value"]
        server.headerType = nil           // the header check would fire first
        #expect(throws: ConfigBuilderError.mkcpObfuscationUnsupported("seed is set")) {
            _ = try XrayConfigBuilder().makeConfig(server: server, anti: .off)
        }
        // Plain mKCP — the case that works — still builds, and its settings
        // carry neither removed key.
        server.headerType = "none"
        server.userData = nil
        let cfg = try XrayConfigBuilder().makeConfig(server: server, anti: .off)
        let proxy = (cfg["outbounds"] as! [[String: Any]]).first { $0["tag"] as? String == "proxy" }!
        let kcp = ((proxy["streamSettings"] as! [String: Any])["kcpSettings"]) as! [String: Any]
        #expect(kcp["seed"] == nil)
        #expect(kcp["header"] == nil)
    }

    /// The cipher is the one Shadowsocks field there is no fallback for: the
    /// engine refuses to start the config (`unknown cipher method`) on an empty
    /// or removed one, so the builder must say it in advance.
    @Test func testShadowsocksCipherIsValidated() throws {
        func ss(_ method: String?) -> ProxyServer {
            ProxyServer(name: "S", proto: .shadowsocks, address: "example.com", port: 8388,
                        credential: "pw", method: method)
        }
        #expect(throws: ConfigBuilderError.shadowsocksMethodMissing) {
            _ = try XrayConfigBuilder().makeConfig(server: ss(nil), anti: .off)
        }
        #expect(throws: ConfigBuilderError.shadowsocksMethodMissing) {
            _ = try XrayConfigBuilder().makeConfig(server: ss("   "), anti: .off)
        }
        #expect(throws: ConfigBuilderError.shadowsocksMethodUnsupported("aes-256-cfb")) {
            _ = try XrayConfigBuilder().makeConfig(server: ss("aes-256-cfb"), anti: .off)
        }
        // Case-insensitive, as the engine matches it.
        for good in ["aes-256-gcm", "AES-256-GCM", "chacha20-ietf-poly1305", "none"] {
            _ = try XrayConfigBuilder().makeConfig(server: ss(good), anti: .off)
        }
    }

    /// TCP http-obfuscation must carry the link's path/Host in the full
    /// `request` — a bare `{"type":"http"}` makes Xray substitute defaults
    /// and silently drop them.
    @Test func testTCPHTTPHeaderCarriesRequest() throws {
        var server = realityServer()
        server.headerType = "http"
        server.path = "/loose"
        server.host = "front.example.com"
        let cfg = try XrayConfigBuilder().makeConfig(server: server, anti: .off)
        let proxy = (cfg["outbounds"] as! [[String: Any]]).first { $0["tag"] as? String == "proxy" }!
        let tcp = ((proxy["streamSettings"] as! [String: Any])["tcpSettings"]) as! [String: Any]
        let header = tcp["header"] as! [String: Any]
        #expect(header["type"] as? String == "http")
        let request = header["request"] as! [String: Any]
        #expect(request["path"] as? [String] == ["/loose"])
        let headers = request["headers"] as! [String: [String]]
        #expect(headers["Host"] == ["front.example.com"])
    }

    /// The vmess `scy` cipher from the link must reach the engine's user
    /// object; nil means the engine default (`auto`) applies.
    @Test func testVMessCipherReachesUserObject() throws {
        func users(vmessCipher: String?) throws -> [[String: Any]] {
            let s = ProxyServer(name: "V", proto: .vmess, address: "vm.example.com", port: 443,
                                credential: "11111111-2222-3333-4444-555555555555",
                                network: .tcp, security: .none, vmessCipher: vmessCipher)
            let cfg = try XrayConfigBuilder().makeConfig(server: s, anti: .off)
            let proxy = (cfg["outbounds"] as! [[String: Any]]).first { $0["tag"] as? String == "proxy" }!
            let settings = proxy["settings"] as! [String: Any]
            return ((settings["vnext"] as! [[String: Any]])[0]["users"]) as! [[String: Any]]
        }
        #expect(try users(vmessCipher: "zero")[0]["security"] as? String == "zero")
        #expect(try users(vmessCipher: nil)[0]["security"] as? String == "auto")
    }

    /// Reality honors the link's ALPN list — CDNs fronting Reality panels
    /// commonly require h2; dropping it made the handshake fail at the edge.
    @Test func testRealityEmitsALPN() throws {
        var server = realityServer()
        server.alpn = ["h2", "http/1.1"]
        let cfg = try XrayConfigBuilder().makeConfig(server: server, anti: .off)
        let proxy = (cfg["outbounds"] as! [[String: Any]]).first { $0["tag"] as? String == "proxy" }!
        let reality = ((proxy["streamSettings"] as! [String: Any])["realitySettings"]) as! [String: Any]
        #expect(reality["alpn"] as? [String] == ["h2", "http/1.1"])

        // Empty list → key omitted entirely (an empty array is a config error).
        var bare = realityServer()
        bare.alpn = []
        let cfg2 = try XrayConfigBuilder().makeConfig(server: bare, anti: .off)
        let proxy2 = (cfg2["outbounds"] as! [[String: Any]]).first { $0["tag"] as? String == "proxy" }!
        let reality2 = ((proxy2["streamSettings"] as! [String: Any])["realitySettings"]) as! [String: Any]
        #expect(reality2["alpn"] == nil)
    }

    /// Plain-TLS servers whose link carried no explicit SNI must fall back to
    /// the transport Host header as serverName — CDN-fronted TLS entries put
    /// the real origin name there, and an absent serverName breaks SNI routing.
    @Test func testTLSServerNameFallsBackToHost() throws {
        var server = realityServer()
        server.security = .tls
        server.network = .ws
        server.sni = nil
        server.host = "origin.example.com"
        let cfg = try XrayConfigBuilder().makeConfig(server: server, anti: .off)
        let proxy = (cfg["outbounds"] as! [[String: Any]]).first { $0["tag"] as? String == "proxy" }!
        let tls = ((proxy["streamSettings"] as! [String: Any])["tlsSettings"]) as! [String: Any]
        #expect(tls["serverName"] as? String == "origin.example.com")
    }
}

struct SubscriptionParserTests {
    @Test func testParsesBase64Blob() throws {
        let links = [
            "vless://uuid-a@a.example.com:443?encryption=none&security=reality&pbk=P&type=tcp#A",
            "trojan://pw@b.example.com:443?type=tcp#B"
        ].joined(separator: "\n")
        let blob = Data(links.utf8).base64EncodedString()
        let result = SubscriptionParser.parse(blob)
        #expect(result.servers.count == 2)
        #expect(result.failures.isEmpty)
        #expect(result.servers[0].proto == .vless)
        #expect(result.servers[1].proto == .trojan)
    }

    @Test func testSkipsBadLinesButKeepsGood() throws {
        let text = """
        vless://uuid-a@a.example.com:443?encryption=none&type=tcp#A
        not-a-link
        garbage://x
        """
        let result = SubscriptionParser.parse(text)
        #expect(result.servers.count == 1)
        #expect(result.failures.count == 1)  // "garbage://" is a failed parse; "not-a-link" is skipped
    }
}