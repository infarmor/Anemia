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
}
