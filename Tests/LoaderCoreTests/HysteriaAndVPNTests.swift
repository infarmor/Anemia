import XCTest
@testable import LoaderCore

/// Hysteria share links + the Amnezia `vpn://` config container.
final class HysteriaAndVPNTests: XCTestCase {

    // MARK: - Hysteria 2 links

    func testParseHysteria2Link() throws {
        let s = try ShareLinkParser.parse(
            "hysteria2://s3cret@hy.example.com:8443?sni=cdn.example.com&insecure=0&obfs=salamander&obfs-password=obfsPass#Hy%20Node")
        XCTAssertEqual(s.proto, .hysteria2)
        XCTAssertEqual(s.name, "Hy Node")
        XCTAssertEqual(s.address, "hy.example.com")
        XCTAssertEqual(s.port, 8443)
        XCTAssertEqual(s.credential, "s3cret")
        XCTAssertEqual(s.sni, "cdn.example.com")
        XCTAssertFalse(s.allowInsecure)
        XCTAssertEqual(s.userData?["obfs"], "salamander")
        XCTAssertEqual(s.userData?["obfsPassword"], "obfsPass")
        XCTAssertEqual(s.userData?["hysteriaVersion"], "2")
    }

    func testParseHy2SchemeAndDefaults() throws {
        // `hy2://` alias, no query → default port 443, insecure flag honored.
        let s = try ShareLinkParser.parse("hy2://pass@1.2.3.4?insecure=1")
        XCTAssertEqual(s.proto, .hysteria2)
        XCTAssertEqual(s.address, "1.2.3.4")
        XCTAssertEqual(s.port, 443)
        XCTAssertEqual(s.credential, "pass")
        XCTAssertTrue(s.allowInsecure)
    }

    func testHysteria2WithoutAuthFails() {
        XCTAssertThrowsError(try ShareLinkParser.parse("hysteria2://1.2.3.4:443#no-auth"))
    }

    // MARK: - Hysteria 1 links

    func testParseHysteria1Link() throws {
        let s = try ShareLinkParser.parse(
            "hysteria://h1.example.com:36712?auth=seekrit&peer=h1.example.com&insecure=1&upmbps=50&downmbps=200&alpn=h3&obfs=xplus&obfsParam=obfsKey#Old%20Hy")
        XCTAssertEqual(s.proto, .hysteria)
        XCTAssertEqual(s.name, "Old Hy")
        XCTAssertEqual(s.credential, "seekrit")
        XCTAssertEqual(s.port, 36712)
        XCTAssertEqual(s.sni, "h1.example.com")
        XCTAssertTrue(s.allowInsecure)
        XCTAssertEqual(s.userData?["upmbps"], "50")
        XCTAssertEqual(s.userData?["downmbps"], "200")
        XCTAssertEqual(s.userData?["obfs"], "xplus")
        XCTAssertEqual(s.userData?["obfsPassword"], "obfsKey")
        XCTAssertEqual(s.userData?["hysteriaVersion"], "1")
        XCTAssertEqual(s.alpn, ["h3"])
    }

    // MARK: - Hysteria engine config

    func testHysteria2ClientYAML() throws {
        let s = try ShareLinkParser.parse(
            "hy2://pass@hy.example.com:8443?sni=cdn.example.com&obfs=salamander&obfs-password=obfsPass")
        let yaml = try HysteriaConfigBuilder.makeClientConfig(server: s, socksPort: 21180)
        XCTAssertTrue(yaml.contains(#"server: "hy.example.com:8443""#), yaml)
        XCTAssertTrue(yaml.contains(#"auth: "pass""#), yaml)
        XCTAssertTrue(yaml.contains(#"sni: "cdn.example.com""#), yaml)
        XCTAssertTrue(yaml.contains(#"type: "salamander""#), yaml)
        XCTAssertTrue(yaml.contains(#"password: "obfsPass""#), yaml)
        XCTAssertTrue(yaml.contains(#"listen: "127.0.0.1:21180""#), yaml)
        // No guessed rate limits: without a bandwidth section the engine runs BBR.
        XCTAssertFalse(yaml.contains("bandwidth"), yaml)
    }

    func testHysteria1ValidatedAsUnsupported() throws {
        let s = try ShareLinkParser.parse("hysteria://h1.example.com:36712?auth=x")
        // The v1 YAML is generated (for tooling), but validation flags the
        // protocol-version mismatch so the connect path refuses to launch it
        // against the v2-only binary.
        let problems = HysteriaConfigBuilder.validate(server: s)
        XCTAssertFalse(problems.isEmpty)
        XCTAssertTrue(problems.contains { $0.contains("v1") })
        // And the generated YAML is the v1 shape (auth_str), should tooling
        // ever wire a legacy binary in.
        let yaml = try HysteriaConfigBuilder.makeClientConfig(server: s, socksPort: 21180)
        XCTAssertTrue(yaml.contains("auth_str"), yaml)
    }

    func testHysteriaXrayConfigRoutesThroughSocksBridge() throws {
        var s = try ShareLinkParser.parse("hy2://pass@hy.example.com:8443")
        s.userData = (s.userData ?? [:]).merging(["hySocksPort": "21180"]) { _, n in n }
        let cfg = try XrayConfigBuilder().makeConfig(server: s)
        let outbounds = cfg["outbounds"] as? [[String: Any]] ?? []
        let proxy = outbounds.first { ($0["tag"] as? String) == "proxy" }
        XCTAssertEqual(proxy?["protocol"] as? String, "socks")
        let servers = (proxy?["settings"] as? [String: Any])?["servers"] as? [[String: Any]]
        XCTAssertEqual(servers?.first?["address"] as? String, "127.0.0.1")
        XCTAssertEqual(servers?.first?["port"] as? Int, 21180)
    }

    func testHysteriaXrayConfigWithoutBridgeThrows() throws {
        let s = try ShareLinkParser.parse("hy2://pass@hy.example.com:8443")
        XCTAssertThrowsError(try XrayConfigBuilder().makeConfig(server: s)) { error in
            XCTAssertEqual(error as? ConfigBuilderError, .hysteriaBridgeMissing)
        }
    }

    // MARK: - Amnezia vpn:// container

    /// A real-shaped Amnezia export: vpn:// + base64url(qCompress(envelope JSON)),
    /// AWG container with double-serialized last_config holding the wg-quick INI.
    static let compressedVPNPayload =
        "AAADiXiclZNbc6IwFMe_CpPXuggBVmSmD_am1dnWrdY6Kx0nC6HNFAMNkXoZv_ueQ3D2YZ8WGP2f37mEkxOO5L2o9APbcBIR3_ZsarukQ1JeJUqUWhQS-JxX2hq8DK0ZVzVXjT9j21xfF1IzIQFFhG0kPwj2jX29YYCsXICu3dwAknNoRaLV8a_5Tyb-RkdSFkrjK3mUYrpWTFbI1qUqdAGebVoCF9X8Xah0ypTew9tkApK12vIOyVml10mLyDEmIzcmkRWTICYd-BtRY4Zha3vGdqnnt8Q3pI-XQePEoDZivBGyBc6ZsJ0hvZbM2mVd93sL2oXdHjUgyQWX2Jio1x98b7z7gTwE87uLbE7DQVCPnHqYXIflYvlZB7-yhXPhTP0n6dbB6PayLdP0arJX91JzlbGEv8axnEJlpvmE761L678Kx3KQpopXFSS6jh3CMGnXo8BvHmbIzHzBHidg-ihgT1A6jWY70D3UMxfjYRNAUpQ9LDNCGqBABrMA5aEXpwDaB232P5Y_5s-NJ8Ry8KymnKumv-3vXCSmvcddUN-8ZOP-PvtYJs_bMV2-TfKfs82wruXVlfP51K8n3h09LJymvTwvvnh6P8UOHbu5u07HiqIurnIr07IQUmND5uOImhOJi8JRFpWGyU04L1kuag5RFHsx8zh_WO0BMenGhQcZcVPrRE6n19MfjpALiw"

    static let plainVPNPayload =
        "eyJob3N0TmFtZSI6IjQuMy4yLjEiLCJkZXNjcmlwdGlvbiI6IlRlc3QgQVdHIFNlcnZlciIsImRlZmF1bHRDb250YWluZXIiOiJhbW5lemlhLWF3ZyIsImRuczEiOiIxLjEuMS4xIiwiY29udGFpbmVycyI6W3siY29udGFpbmVyIjoiYW1uZXppYS1hd2ciLCJhd2ciOnsicG9ydCI6IjQzMjIxIiwidHJhbnNwb3J0X3Byb3RvIjoidWRwIiwiaXNUaGlyZFBhcnR5Q29uZmlnIjp0cnVlLCJsYXN0X2NvbmZpZyI6IntcIkgxXCI6IFwiNVwiLCBcIkgyXCI6IFwiODhcIiwgXCJIM1wiOiBcIjEyMzRcIiwgXCJINFwiOiBcIjk5OTk5XCIsIFwiSmNcIjogXCI0XCIsIFwiSm1pblwiOiBcIjQwXCIsIFwiSm1heFwiOiBcIjcwXCIsIFwiUzFcIjogXCIxMTZcIiwgXCJTMlwiOiBcIjE3MlwiLCBcImNsaWVudF9wcml2X2tleVwiOiBcInlBbno1VEYrZlQyOEE1dkgwdkdjQzhwVlhxdjVaZlYwKzBQNFJuMXY1SEU9XCIsIFwiY29uZmlnXCI6IFwiW0ludGVyZmFjZV1cXG5Qcml2YXRlS2V5ID0geUFuejVURitmVDI4QTV2SDB2R2NDOHBWWHF2NVpmVjArMFA0Um4xdjVIRT1cXG5BZGRyZXNzID0gMTAuOC4xLjIvMzJcXG5ETlMgPSAxLjEuMS4xXFxuSmMgPSA0XFxuSm1pbiA9IDQwXFxuSm1heCA9IDcwXFxuUzEgPSAxMTZcXG5TMiA9IDE3MlxcbkgxID0gNVxcbkgyID0gODhcXG5IMyA9IDEyMzRcXG5INCA9IDk5OTk5XFxuTVRVID0gMTI4MFxcblxcbltQZWVyXVxcblB1YmxpY0tleSA9IE94NXZEV2ZKOXlma1hjVXVKMlhnS2xRU21HdnZuQkIwcVI5dkszRjJ6VjA9XFxuQWxsb3dlZElQcyA9IDAuMC4wLjAvMCwgOjovMFxcbkVuZHBvaW50ID0gNC4zLjIuMTo0MzIyMVxcblBlcnNpc3RlbnRLZWVwYWxpdmUgPSAyNVxcblwiLCBcImhvc3ROYW1lXCI6IFwiNC4zLjIuMVwiLCBcInBvcnRcIjogNDMyMjF9In19XX0"

    func testParseVPNLinkCompressed() throws {
        let s = try ShareLinkParser.parse("vpn://" + Self.compressedVPNPayload)
        XCTAssertEqual(s.proto, .amnezia)
        XCTAssertEqual(s.name, "Test AWG Server")
        XCTAssertEqual(s.address, "4.3.2.1")
        XCTAssertEqual(s.port, 43221)
        XCTAssertEqual(s.credential, "yAnz5TF+fT28A5vH0vGcC8pVXqv5ZfV0+0P4Rn1v5HE=")
        XCTAssertEqual(s.wgProfile?.peerPublicKey, "Ox5vDWfJ9yfkXcUuJ2XgKlQSmGvvnBB0qR9vK3F2zV0=")
        XCTAssertEqual(s.awg?.junkPackets, 4)
        XCTAssertEqual(s.awg?.junkMin, 40)
        XCTAssertEqual(s.awg?.junkMax, 70)
        XCTAssertEqual(s.awg?.initPadding, 116)
        XCTAssertEqual(s.awg?.responsePadding, 172)
        XCTAssertEqual(s.awg?.header1, "5")
        XCTAssertEqual(s.awg?.header4, "99999")
        XCTAssertEqual(s.userData?["wgAddress"], "10.8.1.2/32")
    }

    func testParseVPNLinkUncompressedFallback() throws {
        let s = try ShareLinkParser.parse("vpn://" + Self.plainVPNPayload)
        XCTAssertEqual(s.proto, .amnezia)
        XCTAssertEqual(s.name, "Test AWG Server")
        XCTAssertEqual(s.address, "4.3.2.1")
        XCTAssertEqual(s.port, 43221)
        XCTAssertEqual(s.credential, "yAnz5TF+fT28A5vH0vGcC8pVXqv5ZfV0+0P4Rn1v5HE=")
    }

    func testParseVPNLinkGarbageThrows() {
        // Valid base64 but not an Amnezia envelope.
        XCTAssertThrowsError(try ShareLinkParser.parse("vpn://aGVsbG8gd29ybGQ="))
        // Not even base64.
        XCTAssertThrowsError(try ShareLinkParser.parse("vpn://@@@"))
    }
}