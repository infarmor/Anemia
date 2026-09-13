import XCTest
@testable import LoaderCore

final class ShareLinkParserTests: XCTestCase {

    func testParseVLESSReality() throws {
        let link = "vless://b831381d-6324-4d53-ad4f-8cda48b30811@example.com:443" +
            "?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome" +
            "&pbk=PUBKEY123&sid=abcd&spx=%2F&type=tcp&flow=xtls-rprx-vision#My%20Reality"

        let s = try ShareLinkParser.parse(link)
        XCTAssertEqual(s.proto, .vless)
        XCTAssertEqual(s.address, "example.com")
        XCTAssertEqual(s.port, 443)
        XCTAssertEqual(s.credential, "b831381d-6324-4d53-ad4f-8cda48b30811")
        XCTAssertEqual(s.security, .reality)
        XCTAssertEqual(s.sni, "www.microsoft.com")
        XCTAssertEqual(s.fingerprint, "chrome")
        XCTAssertEqual(s.realityPublicKey, "PUBKEY123")
        XCTAssertEqual(s.realityShortId, "abcd")
        XCTAssertEqual(s.realitySpiderX, "/")
        XCTAssertEqual(s.flow, "xtls-rprx-vision")
        XCTAssertEqual(s.network, .tcp)
        XCTAssertEqual(s.name, "My Reality")
    }

    func testParseVLESSWebSocketTLS() throws {
        let link = "vless://uuid-1@cdn.example.net:8443" +
            "?encryption=none&security=tls&type=ws&path=%2Fwspath&host=cdn.example.net&sni=cdn.example.net#WS"
        let s = try ShareLinkParser.parse(link)
        XCTAssertEqual(s.network, .ws)
        XCTAssertEqual(s.security, .tls)
        XCTAssertEqual(s.path, "/wspath")
        XCTAssertEqual(s.host, "cdn.example.net")
    }

    func testParseTrojanDefaultsToTLS() throws {
        let link = "trojan://sekret-pass@t.example.org:443?type=tcp#Trojan"
        let s = try ShareLinkParser.parse(link)
        XCTAssertEqual(s.proto, .trojan)
        XCTAssertEqual(s.credential, "sekret-pass")
        XCTAssertEqual(s.security, .tls)   // implied
        XCTAssertEqual(s.port, 443)
    }

    func testParseVMess() throws {
        let json = """
        {"v":"2","ps":"Node-JP","add":"jp.example.com","port":"443","id":"11111111-2222-3333-4444-555555555555","aid":"0","scy":"auto","net":"ws","type":"none","host":"jp.example.com","path":"/vm","tls":"tls","sni":"jp.example.com","fp":"chrome"}
        """
        let b64 = Data(json.utf8).base64EncodedString()
        let s = try ShareLinkParser.parse("vmess://\(b64)")
        XCTAssertEqual(s.proto, .vmess)
        XCTAssertEqual(s.name, "Node-JP")
        XCTAssertEqual(s.address, "jp.example.com")
        XCTAssertEqual(s.port, 443)
        XCTAssertEqual(s.credential, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(s.alterId, 0)
        XCTAssertEqual(s.network, .ws)
        XCTAssertEqual(s.security, .tls)
        XCTAssertEqual(s.path, "/vm")
        XCTAssertEqual(s.host, "jp.example.com")
    }

    func testParseShadowsocksSIP002() throws {
        let userInfo = "aes-256-gcm:mypassword"
        let b64 = Data(userInfo.utf8).base64EncodedString()
        let s = try ShareLinkParser.parse("ss://\(b64)@ss.example.com:8388#SS-Node")
        XCTAssertEqual(s.proto, .shadowsocks)
        XCTAssertEqual(s.method, "aes-256-gcm")
        XCTAssertEqual(s.credential, "mypassword")
        XCTAssertEqual(s.address, "ss.example.com")
        XCTAssertEqual(s.port, 8388)
        XCTAssertEqual(s.name, "SS-Node")
    }

    /// SIP002 generators that percent-encode the base64 userinfo (`=` as
    /// %3D, `+`/`/` as %2B/%2F) used to fail with malformedURI: the first
    /// decode ran on the still-encoded string and the fallback never retried
    /// base64 after percent-decoding.
    func testParseShadowsocksSIP002PercentEncodedBase64() throws {
        let userInfo = "aes-256-gcm:mypassword"
        var b64 = Data(userInfo.utf8).base64EncodedString()
        b64 = b64.replacingOccurrences(of: "=", with: "%3D")
        let s = try ShareLinkParser.parse("ss://\(b64)@ss.example.com:8388#SS-Node")
        XCTAssertEqual(s.method, "aes-256-gcm")
        XCTAssertEqual(s.credential, "mypassword")
        XCTAssertEqual(s.address, "ss.example.com")
        XCTAssertEqual(s.port, 8388)
    }

    /// Plain percent-encoded `method:password` userinfo (`:` as %3A) must
    /// survive the base64-retry path too — the retry must not swallow it.
    func testParseShadowsocksSIP002PlainPercentEncoded() throws {
        let s = try ShareLinkParser.parse("ss://aes-256-gcm%3AmyPassword@ss.example.com:8388#SS")
        XCTAssertEqual(s.method, "aes-256-gcm")
        XCTAssertEqual(s.credential, "myPassword")
        XCTAssertEqual(s.address, "ss.example.com")
        XCTAssertEqual(s.port, 8388)
    }

    func testParseShadowsocksLegacy() throws {
        let whole = "chacha20-ietf-poly1305:pw123@legacy.example.com:8389"
        let b64 = Data(whole.utf8).base64EncodedString()
        let s = try ShareLinkParser.parse("ss://\(b64)#Legacy")
        XCTAssertEqual(s.method, "chacha20-ietf-poly1305")
        XCTAssertEqual(s.credential, "pw123")
        XCTAssertEqual(s.address, "legacy.example.com")
        XCTAssertEqual(s.port, 8389)
    }

    func testUnsupportedSchemeThrows() {
        XCTAssertThrowsError(try ShareLinkParser.parse("http://example.com")) { err in
            XCTAssertEqual(err as? ParseError, .unsupportedScheme("http"))
        }
    }

    func testIPv6Host() throws {
        let link = "vless://uuid-9@[2606:4700:4700::1111]:443?encryption=none&security=tls&type=tcp#v6"
        let s = try ShareLinkParser.parse(link)
        XCTAssertEqual(s.address, "2606:4700:4700::1111")
        XCTAssertEqual(s.port, 443)
    }

    // MARK: Transport normalization

    /// Real-world links spell the same transport several ways; aliases must
    /// all map to the canonical NetworkType.
    func testTransportAliases() throws {
        func net(_ type: String) throws -> NetworkType {
            try ShareLinkParser.parse(
                "vless://u@h.example.com:443?security=tls&type=\(type)#n").network
        }
        XCTAssertEqual(try net("h2"), .http)
        XCTAssertEqual(try net("kcp"), .kcp)
        XCTAssertEqual(try net("mkcp"), .kcp)
        XCTAssertEqual(try net("raw"), .tcp)
        XCTAssertEqual(try net("none"), .tcp)  // panels emit type=none for plain TCP
        XCTAssertEqual(try net("websocket"), .ws)
        XCTAssertEqual(try net("httpupgrade"), .httpupgrade)
    }

    /// An unknown transport must fail the parse loudly — the old silent
    /// `.tcp` fallback wired the link to a plain-TCP connection that could
    /// never complete the real handshake.
    func testUnknownTransportThrows() {
        XCTAssertThrowsError(
            try ShareLinkParser.parse("vless://u@h.example.com:443?type=xhttp#n")
        ) { err in
            XCTAssertEqual(err as? ParseError, ParseError.unsupportedTransport("xhttp"))
        }
    }

    // MARK: gRPC extras

    func testGRPCModeAndAuthority() throws {
        let link = "vless://u@g.example.com:443?security=tls&type=grpc" +
            "&serviceName=GunSvc&host=front.example.com&mode=multi#GR"
        let s = try ShareLinkParser.parse(link)
        XCTAssertEqual(s.network, .grpc)
        XCTAssertEqual(s.path, "GunSvc")
        XCTAssertEqual(s.host, "front.example.com")
        XCTAssertEqual(s.grpcMultiMode, true)
    }

    func testGRPCDefaultsToSingleMode() throws {
        let link = "vless://u@g.example.com:443?security=tls&type=grpc&serviceName=GunSvc#GR"
        let s = try ShareLinkParser.parse(link)
        XCTAssertNotEqual(s.grpcMultiMode, true)
    }

    // MARK: SIP002 host:port edge cases

    /// SIP002 permits a trailing path after the port (`host:8388/` or
    /// `host:8388/?plugin=…`); the path is decoration, not part of the
    /// authority, and used to break the whole import.
    func testSIP002TrailingPath() throws {
        let b64 = Data("aes-256-gcm:pw".utf8).base64EncodedString()
        let s = try ShareLinkParser.parse("ss://\(b64)@ss.example.com:8388/#SS")
        XCTAssertEqual(s.address, "ss.example.com")
        XCTAssertEqual(s.port, 8388)
    }

    /// A SIP002 `plugin=` names an external helper process (obfs-local, v2ray-plugin)
    /// the app never bundles: parsing it silently used to import a server that
    /// could only fail at connect time with an opaque TLS/reset error. It must
    /// fail loudly at import instead.
    func testSIP002PluginFailsLoud() {
        let b64 = Data("aes-256-gcm:pw".utf8).base64EncodedString()
        XCTAssertThrowsError(try ShareLinkParser.parse(
            "ss://\(b64)@ss.example.com:8388/?plugin=obfs-local%3Bobfs%3Dhttp#SS")) { error in
            guard case ParseError.unsupportedTransport(let detail) = error,
                  detail.contains("obfs-local")
            else { return XCTFail("expected unsupportedTransport(obfs-local…), got \(error)") }
        }
    }

    /// v2rayN-style links are pasted with a `#name` or `?note` suffix after the
    /// base64 body; strict base64 decode used to choke on the suffix's letters
    /// and the whole link read as "invalid".
    func testParseVMessFragmentAndQueryPeel() throws {
        let json = """
        {"v":"2","ps":"Node-FR","add":"fr.example.com","port":"443","id":"11111111-2222-3333-4444-555555555555","aid":"0","net":"tcp","tls":"tls"}
        """
        let b64 = Data(json.utf8).base64EncodedString()
        for suffix in ["#renamed", "?added=later", "#a%20b?not-json"] {
            let s = try ShareLinkParser.parse("vmess://\(b64)\(suffix)")
            XCTAssertEqual(s.address, "fr.example.com")
            XCTAssertEqual(s.name, "Node-FR")
            XCTAssertEqual(s.security, .tls)
        }
    }

    /// `tls` may arrive as a JSON Bool (true/false) or the strings "tls"/"" —
    /// and v2rayN sends `"tls": "xtls"` for legacy XTLS links, which must map
    /// to the tolerated `.xtls` security, not fall back to `none`.
    func testParseVMessTLSVariants() throws {
        func parse(tls: String) throws -> ProxyServer {
            let json = """
            {"v":"2","ps":"N","add":"a.example.com","port":"443","id":"11111111-2222-3333-4444-555555555555","aid":"0","net":"tcp","tls":\(tls)}
            """
            let b64 = Data(json.utf8).base64EncodedString()
            return try ShareLinkParser.parse("vmess://\(b64)")
        }
        XCTAssertEqual(try parse(tls: "true").security, .tls)
        XCTAssertEqual(try parse(tls: "false").security, .none)
        XCTAssertEqual(try parse(tls: "\"tls\"").security, .tls)
        XCTAssertEqual(try parse(tls: "\"xtls\"").security, .xtls)
        XCTAssertEqual(try parse(tls: "\"none\"").security, .none)
    }

    /// The vmess `scy` cipher travels to the engine's user object; a link with
    /// `scy: "zero"` that imported as cipher `auto` would fail auth silently.
    func testParseVMessScyCipher() throws {
        let json = """
        {"v":"2","ps":"N","add":"a.example.com","port":"443","id":"11111111-2222-3333-4444-555555555555","aid":"0","scy":"zero","net":"tcp","tls":"none"}
        """
        let b64 = Data(json.utf8).base64EncodedString()
        let s = try ShareLinkParser.parse("vmess://\(b64)")
        XCTAssertEqual(s.vmessCipher, "zero")

        let noScy = """
        {"v":"2","ps":"N","add":"a.example.com","port":"443","id":"11111111-2222-3333-4444-555555555555","aid":"0","net":"tcp","tls":"none"}
        """
        let s2 = try ShareLinkParser.parse("vmess://\(Data(noScy.utf8).base64EncodedString())")
        XCTAssertNil(s2.vmessCipher)   // engine default (auto) applies
    }
}
