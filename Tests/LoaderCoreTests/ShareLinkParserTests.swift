import Foundation
import Testing
@testable import LoaderCore

struct ShareLinkParserTests {

    @Test func testParseVLESSReality() throws {
        let link = "vless://b831381d-6324-4d53-ad4f-8cda48b30811@example.com:443" +
            "?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome" +
            "&pbk=PUBKEY123&sid=abcd&spx=%2F&type=tcp&flow=xtls-rprx-vision#My%20Reality"

        let s = try ShareLinkParser.parse(link)
        #expect(s.proto == .vless)
        #expect(s.address == "example.com")
        #expect(s.port == 443)
        #expect(s.credential == "b831381d-6324-4d53-ad4f-8cda48b30811")
        #expect(s.security == .reality)
        #expect(s.sni == "www.microsoft.com")
        #expect(s.fingerprint == "chrome")
        #expect(s.realityPublicKey == "PUBKEY123")
        #expect(s.realityShortId == "abcd")
        #expect(s.realitySpiderX == "/")
        #expect(s.flow == "xtls-rprx-vision")
        #expect(s.network == .tcp)
        #expect(s.name == "My Reality")
    }

    @Test func testParseVLESSWebSocketTLS() throws {
        let link = "vless://uuid-1@cdn.example.net:8443" +
            "?encryption=none&security=tls&type=ws&path=%2Fwspath&host=cdn.example.net&sni=cdn.example.net#WS"
        let s = try ShareLinkParser.parse(link)
        #expect(s.network == .ws)
        #expect(s.security == .tls)
        #expect(s.path == "/wspath")
        #expect(s.host == "cdn.example.net")
    }

    @Test func testParseTrojanDefaultsToTLS() throws {
        let link = "trojan://sekret-pass@t.example.org:443?type=tcp#Trojan"
        let s = try ShareLinkParser.parse(link)
        #expect(s.proto == .trojan)
        #expect(s.credential == "sekret-pass")
        #expect(s.security == .tls)   // implied
        #expect(s.port == 443)
    }

    @Test func testParseVMess() throws {
        let json = """
        {"v":"2","ps":"Node-JP","add":"jp.example.com","port":"443","id":"11111111-2222-3333-4444-555555555555","aid":"0","scy":"auto","net":"ws","type":"none","host":"jp.example.com","path":"/vm","tls":"tls","sni":"jp.example.com","fp":"chrome"}
        """
        let b64 = Data(json.utf8).base64EncodedString()
        let s = try ShareLinkParser.parse("vmess://\(b64)")
        #expect(s.proto == .vmess)
        #expect(s.name == "Node-JP")
        #expect(s.address == "jp.example.com")
        #expect(s.port == 443)
        #expect(s.credential == "11111111-2222-3333-4444-555555555555")
        #expect(s.alterId == 0)
        #expect(s.network == .ws)
        #expect(s.security == .tls)
        #expect(s.path == "/vm")
        #expect(s.host == "jp.example.com")
    }

    @Test func testParseShadowsocksSIP002() throws {
        let userInfo = "aes-256-gcm:mypassword"
        let b64 = Data(userInfo.utf8).base64EncodedString()
        let s = try ShareLinkParser.parse("ss://\(b64)@ss.example.com:8388#SS-Node")
        #expect(s.proto == .shadowsocks)
        #expect(s.method == "aes-256-gcm")
        #expect(s.credential == "mypassword")
        #expect(s.address == "ss.example.com")
        #expect(s.port == 8388)
        #expect(s.name == "SS-Node")
    }

    /// SIP002 generators that percent-encode the base64 userinfo (`=` as
    /// %3D, `+`/`/` as %2B/%2F) used to fail with malformedURI: the first
    /// decode ran on the still-encoded string and the fallback never retried
    /// base64 after percent-decoding.
    @Test func testParseShadowsocksSIP002PercentEncodedBase64() throws {
        let userInfo = "aes-256-gcm:mypassword"
        var b64 = Data(userInfo.utf8).base64EncodedString()
        b64 = b64.replacingOccurrences(of: "=", with: "%3D")
        let s = try ShareLinkParser.parse("ss://\(b64)@ss.example.com:8388#SS-Node")
        #expect(s.method == "aes-256-gcm")
        #expect(s.credential == "mypassword")
        #expect(s.address == "ss.example.com")
        #expect(s.port == 8388)
    }

    /// Plain percent-encoded `method:password` userinfo (`:` as %3A) must
    /// survive the base64-retry path too — the retry must not swallow it.
    @Test func testParseShadowsocksSIP002PlainPercentEncoded() throws {
        let s = try ShareLinkParser.parse("ss://aes-256-gcm%3AmyPassword@ss.example.com:8388#SS")
        #expect(s.method == "aes-256-gcm")
        #expect(s.credential == "myPassword")
        #expect(s.address == "ss.example.com")
        #expect(s.port == 8388)
    }

    @Test func testParseShadowsocksLegacy() throws {
        let whole = "chacha20-ietf-poly1305:pw123@legacy.example.com:8389"
        let b64 = Data(whole.utf8).base64EncodedString()
        let s = try ShareLinkParser.parse("ss://\(b64)#Legacy")
        #expect(s.method == "chacha20-ietf-poly1305")
        #expect(s.credential == "pw123")
        #expect(s.address == "legacy.example.com")
        #expect(s.port == 8389)
    }

    @Test func testUnsupportedSchemeThrows() throws {
        if let err = #expect(throws: (any Error).self, performing: { try ShareLinkParser.parse("http://example.com") }) {
            #expect(err as? ParseError == .unsupportedScheme("http"))
        }
    }

    @Test func testIPv6Host() throws {
        let link = "vless://uuid-9@[2606:4700:4700::1111]:443?encryption=none&security=tls&type=tcp#v6"
        let s = try ShareLinkParser.parse(link)
        #expect(s.address == "2606:4700:4700::1111")
        #expect(s.port == 443)
    }

    // MARK: Transport normalization

    /// Real-world links spell the same transport several ways; aliases must
    /// all map to the canonical NetworkType.
    @Test func testTransportAliases() throws {
        func net(_ type: String) throws -> NetworkType {
            try ShareLinkParser.parse(
                "vless://u@h.example.com:443?security=tls&type=\(type)#n").network
        }
        #expect(try net("h2") == .http)
        #expect(try net("kcp") == .kcp)
        #expect(try net("mkcp") == .kcp)
        #expect(try net("raw") == .tcp)
        #expect(try net("none") == .tcp)  // panels emit type=none for plain TCP
        #expect(try net("websocket") == .ws)
        #expect(try net("httpupgrade") == .httpupgrade)
    }

    /// An unknown transport must fail the parse loudly — the old silent
    /// `.tcp` fallback wired the link to a plain-TCP connection that could
    /// never complete the real handshake.
    @Test func testUnknownTransportThrows() throws {
        if let err = #expect(throws: (any Error).self, performing: { try ShareLinkParser.parse("vless://u@h.example.com:443?type=carrier-pigeon#n") }) {
            #expect(err as? ParseError == ParseError.unsupportedTransport("carrier-pigeon"))
        }
        // XHTTP is not unknown: the bundled engine runs it (ProtocolCoverageTests).
        #expect(try ShareLinkParser.parse("vless://u@h.example.com:443?type=xhttp#n").network == .xhttp)
    }

    // MARK: gRPC extras

    @Test func testGRPCModeAndAuthority() throws {
        let link = "vless://u@g.example.com:443?security=tls&type=grpc" +
            "&serviceName=GunSvc&host=front.example.com&mode=multi#GR"
        let s = try ShareLinkParser.parse(link)
        #expect(s.network == .grpc)
        #expect(s.path == "GunSvc")
        #expect(s.host == "front.example.com")
        #expect(s.grpcMultiMode == true)
    }

    @Test func testGRPCDefaultsToSingleMode() throws {
        let link = "vless://u@g.example.com:443?security=tls&type=grpc&serviceName=GunSvc#GR"
        let s = try ShareLinkParser.parse(link)
        #expect(s.grpcMultiMode != true)
    }

    // MARK: SIP002 host:port edge cases

    /// SIP002 permits a trailing path after the port (`host:8388/` or
    /// `host:8388/?plugin=…`); the path is decoration, not part of the
    /// authority, and used to break the whole import.
    @Test func testSIP002TrailingPath() throws {
        let b64 = Data("aes-256-gcm:pw".utf8).base64EncodedString()
        let s = try ShareLinkParser.parse("ss://\(b64)@ss.example.com:8388/#SS")
        #expect(s.address == "ss.example.com")
        #expect(s.port == 8388)
    }

    /// A SIP002 `plugin=` names an external helper process (obfs-local, v2ray-plugin)
    /// the app never bundles: parsing it silently used to import a server that
    /// could only fail at connect time with an opaque TLS/reset error. It must
    /// fail loudly at import instead.
    @Test func testSIP002PluginFailsLoud() throws {
        let b64 = Data("aes-256-gcm:pw".utf8).base64EncodedString()
        if let error = #expect(throws: (any Error).self, performing: { try ShareLinkParser.parse(
            "ss://\(b64)@ss.example.com:8388/?plugin=obfs-local%3Bobfs%3Dhttp#SS") }) {
            guard case ParseError.unsupportedTransport(let detail) = error,
                  detail.contains("obfs-local")
            else { Issue.record("expected unsupportedTransport(obfs-local…), got \(error)"); return }
        }
    }

    /// v2rayN-style links are pasted with a `#name` or `?note` suffix after the
    /// base64 body; strict base64 decode used to choke on the suffix's letters
    /// and the whole link read as "invalid".
    @Test func testParseVMessFragmentAndQueryPeel() throws {
        let json = """
        {"v":"2","ps":"Node-FR","add":"fr.example.com","port":"443","id":"11111111-2222-3333-4444-555555555555","aid":"0","net":"tcp","tls":"tls"}
        """
        let b64 = Data(json.utf8).base64EncodedString()
        for suffix in ["#renamed", "?added=later", "#a%20b?not-json"] {
            let s = try ShareLinkParser.parse("vmess://\(b64)\(suffix)")
            #expect(s.address == "fr.example.com")
            #expect(s.name == "Node-FR")
            #expect(s.security == .tls)
        }
    }

    /// `tls` may arrive as a JSON Bool (true/false) or the strings "tls"/"" —
    /// and v2rayN sends `"tls": "xtls"` for legacy XTLS links, which must map
    /// to the tolerated `.xtls` security, not fall back to `none`.
    @Test func testParseVMessTLSVariants() throws {
        func parse(tls: String) throws -> ProxyServer {
            let json = """
            {"v":"2","ps":"N","add":"a.example.com","port":"443","id":"11111111-2222-3333-4444-555555555555","aid":"0","net":"tcp","tls":\(tls)}
            """
            let b64 = Data(json.utf8).base64EncodedString()
            return try ShareLinkParser.parse("vmess://\(b64)")
        }
        #expect(try parse(tls: "true").security == .tls)
        #expect(try parse(tls: "false").security == .none)
        #expect(try parse(tls: "\"tls\"").security == .tls)
        #expect(try parse(tls: "\"xtls\"").security == .xtls)
        #expect(try parse(tls: "\"none\"").security == .none)
    }

    /// The vmess `scy` cipher travels to the engine's user object; a link with
    /// `scy: "zero"` that imported as cipher `auto` would fail auth silently.
    @Test func testParseVMessScyCipher() throws {
        let json = """
        {"v":"2","ps":"N","add":"a.example.com","port":"443","id":"11111111-2222-3333-4444-555555555555","aid":"0","scy":"zero","net":"tcp","tls":"none"}
        """
        let b64 = Data(json.utf8).base64EncodedString()
        let s = try ShareLinkParser.parse("vmess://\(b64)")
        #expect(s.vmessCipher == "zero")

        let noScy = """
        {"v":"2","ps":"N","add":"a.example.com","port":"443","id":"11111111-2222-3333-4444-555555555555","aid":"0","net":"tcp","tls":"none"}
        """
        let s2 = try ShareLinkParser.parse("vmess://\(Data(noScy.utf8).base64EncodedString())")
        #expect(s2.vmessCipher == nil)   // engine default (auto) applies
    }

    /// 3x-ui (and some other panels) encode an AmneziaWG share link as
    /// `vpn://` + base64(url) of the verbatim wg-quick `.conf` — not the
    /// AmneziaVPN JSON envelope the scheme usually carries. The parser must
    /// recognize the raw `[Interface]` config inside the payload instead of
    /// throwing "not an Amnezia config".
    @Test func testParseVPNLinkWithRawWireGuardConf() throws {
        let conf = """
        [Interface]
        PrivateKey = QNsPY4MKVPm7M1ce26YOYEnctjtEUS6qzPCbcFiOh1w=
        Address = 10.8.1.2/32
        DNS = 8.8.8.8, 1.1.1.1
        MTU = 1420
        Jc = 4
        Jmin = 50
        Jmax = 1000
        S1 = 19
        S2 = 88
        H1 = 1616798576
        H2 = 1525850419
        H3 = 1876586336
        H4 = 1694665168
        I1 = <r 148>

        # Anemia AmneziaWG
        [Peer]
        PublicKey = abcdEFGH1234ijklMNOP5678qrstUVWX90+/abcdEFG=
        AllowedIPs = 0.0.0.0/0, ::/0
        Endpoint = vpn.example.com:38251
        """
        let link = "vpn://\(Data(conf.utf8).base64EncodedString())"
        let s = try ShareLinkParser.parse(link)
        #expect(s.proto.isWireGuardFamily)
        #expect(s.address == "vpn.example.com")
        #expect(s.port == 38251)
    }
}
