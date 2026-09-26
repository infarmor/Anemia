import Foundation
import Testing
@testable import LoaderCore

/// Hysteria share links + the Amnezia `vpn://` config container.
struct HysteriaAndVPNTests {

    // MARK: - Hysteria 2 links

    @Test func testParseHysteria2Link() throws {
        let s = try ShareLinkParser.parse(
            "hysteria2://s3cret@hy.example.com:8443?sni=cdn.example.com&insecure=0&obfs=salamander&obfs-password=obfsPass#Hy%20Node")
        #expect(s.proto == .hysteria2)
        #expect(s.name == "Hy Node")
        #expect(s.address == "hy.example.com")
        #expect(s.port == 8443)
        #expect(s.credential == "s3cret")
        #expect(s.sni == "cdn.example.com")
        #expect(!s.allowInsecure)
        #expect(s.userData?["obfs"] == "salamander")
        #expect(s.userData?["obfsPassword"] == "obfsPass")
        #expect(s.userData?["hysteriaVersion"] == "2")
    }

    @Test func testParseHy2SchemeAndDefaults() throws {
        // `hy2://` alias, no query → default port 443, insecure flag honored.
        let s = try ShareLinkParser.parse("hy2://pass@1.2.3.4?insecure=1")
        #expect(s.proto == .hysteria2)
        #expect(s.address == "1.2.3.4")
        #expect(s.port == 443)
        #expect(s.credential == "pass")
        #expect(s.allowInsecure)
    }

    @Test func testHysteria2WithoutAuthFails() throws {
        #expect(throws: (any Error).self) { try ShareLinkParser.parse("hysteria2://1.2.3.4:443#no-auth") }
    }

    // MARK: - Hysteria 1 links

    @Test func testParseHysteria1Link() throws {
        let s = try ShareLinkParser.parse(
            "hysteria://h1.example.com:36712?auth=seekrit&peer=h1.example.com&insecure=1&upmbps=50&downmbps=200&alpn=h3&obfs=xplus&obfsParam=obfsKey#Old%20Hy")
        #expect(s.proto == .hysteria)
        #expect(s.name == "Old Hy")
        #expect(s.credential == "seekrit")
        #expect(s.port == 36712)
        #expect(s.sni == "h1.example.com")
        #expect(s.allowInsecure)
        #expect(s.userData?["upmbps"] == "50")
        #expect(s.userData?["downmbps"] == "200")
        #expect(s.userData?["obfs"] == "xplus")
        #expect(s.userData?["obfsPassword"] == "obfsKey")
        #expect(s.userData?["hysteriaVersion"] == "1")
        #expect(s.alpn == ["h3"])
    }

    // MARK: - Hysteria engine config

    @Test func testHysteria2ClientYAML() throws {
        let s = try ShareLinkParser.parse(
            "hy2://pass@hy.example.com:8443?sni=cdn.example.com&obfs=salamander&obfs-password=obfsPass")
        let yaml = try HysteriaConfigBuilder.makeClientConfig(server: s, socksPort: 21180)
        #expect(yaml.contains(#"server: "hy.example.com:8443""#), "\(yaml)")
        #expect(yaml.contains(#"auth: "pass""#), "\(yaml)")
        #expect(yaml.contains(#"sni: "cdn.example.com""#), "\(yaml)")
        #expect(yaml.contains(#"type: "salamander""#), "\(yaml)")
        #expect(yaml.contains(#"password: "obfsPass""#), "\(yaml)")
        #expect(yaml.contains(#"listen: "127.0.0.1:21180""#), "\(yaml)")
        // No guessed rate limits: without a bandwidth section the engine runs BBR.
        #expect(!yaml.contains("bandwidth"), "\(yaml)")
    }

    @Test func testHysteria1ValidatedAsUnsupported() throws {
        let s = try ShareLinkParser.parse("hysteria://h1.example.com:36712?auth=x")
        // The v1 YAML is generated (for tooling), but validation flags the
        // protocol-version mismatch so the connect path refuses to launch it
        // against the v2-only binary.
        let problems = HysteriaConfigBuilder.validate(server: s)
        #expect(!problems.isEmpty)
        #expect(problems.contains { $0.contains("v1") })
        // And the generated YAML is the v1 shape (auth_str), should tooling
        // ever wire a legacy binary in.
        let yaml = try HysteriaConfigBuilder.makeClientConfig(server: s, socksPort: 21180)
        #expect(yaml.contains("auth_str"), "\(yaml)")
    }

    @Test func testHysteriaXrayConfigRoutesThroughSocksBridge() throws {
        var s = try ShareLinkParser.parse("hy2://pass@hy.example.com:8443")
        s.userData = (s.userData ?? [:]).merging(["hySocksPort": "21180"]) { _, n in n }
        let cfg = try XrayConfigBuilder().makeConfig(server: s)
        let outbounds = cfg["outbounds"] as? [[String: Any]] ?? []
        let proxy = outbounds.first { ($0["tag"] as? String) == "proxy" }
        #expect(proxy?["protocol"] as? String == "socks")
        let servers = (proxy?["settings"] as? [String: Any])?["servers"] as? [[String: Any]]
        #expect(servers?.first?["address"] as? String == "127.0.0.1")
        #expect(servers?.first?["port"] as? Int == 21180)
    }

    @Test func testHysteriaXrayConfigWithoutBridgeThrows() throws {
        let s = try ShareLinkParser.parse("hy2://pass@hy.example.com:8443")
        if let error = #expect(throws: (any Error).self, performing: { try XrayConfigBuilder().makeConfig(server: s) }) {
            #expect(error as? ConfigBuilderError == .hysteriaBridgeMissing)
        }
    }

    // MARK: - Amnezia vpn:// container

    /// A real-shaped Amnezia export: vpn:// + base64url(qCompress(envelope JSON)),
    /// AWG container with double-serialized last_config holding the wg-quick INI.
    static let compressedVPNPayload =
        "AAADiXiclZNbc6IwFMe_CpPXuggBVmSmD_am1dnWrdY6Kx0nC6HNFAMNkXoZv_ueQ3D2YZ8WGP2f37mEkxOO5L2o9APbcBIR3_ZsarukQ1JeJUqUWhQS-JxX2hq8DK0ZVzVXjT9j21xfF1IzIQFFhG0kPwj2jX29YYCsXICu3dwAknNoRaLV8a_5Tyb-RkdSFkrjK3mUYrpWTFbI1qUqdAGebVoCF9X8Xah0ypTew9tkApK12vIOyVml10mLyDEmIzcmkRWTICYd-BtRY4Zha3vGdqnnt8Q3pI-XQePEoDZivBGyBc6ZsJ0hvZbM2mVd93sL2oXdHjUgyQWX2Jio1x98b7z7gTwE87uLbE7DQVCPnHqYXIflYvlZB7-yhXPhTP0n6dbB6PayLdP0arJX91JzlbGEv8axnEJlpvmE761L678Kx3KQpopXFSS6jh3CMGnXo8BvHmbIzHzBHidg-ihgT1A6jWY70D3UMxfjYRNAUpQ9LDNCGqBABrMA5aEXpwDaB232P5Y_5s-NJ8Ry8KymnKumv-3vXCSmvcddUN-8ZOP-PvtYJs_bMV2-TfKfs82wruXVlfP51K8n3h09LJymvTwvvnh6P8UOHbu5u07HiqIurnIr07IQUmND5uOImhOJi8JRFpWGyU04L1kuag5RFHsx8zh_WO0BMenGhQcZcVPrRE6n19MfjpALiw"

    static let plainVPNPayload =
        "eyJob3N0TmFtZSI6IjQuMy4yLjEiLCJkZXNjcmlwdGlvbiI6IlRlc3QgQVdHIFNlcnZlciIsImRlZmF1bHRDb250YWluZXIiOiJhbW5lemlhLWF3ZyIsImRuczEiOiIxLjEuMS4xIiwiY29udGFpbmVycyI6W3siY29udGFpbmVyIjoiYW1uZXppYS1hd2ciLCJhd2ciOnsicG9ydCI6IjQzMjIxIiwidHJhbnNwb3J0X3Byb3RvIjoidWRwIiwiaXNUaGlyZFBhcnR5Q29uZmlnIjp0cnVlLCJsYXN0X2NvbmZpZyI6IntcIkgxXCI6IFwiNVwiLCBcIkgyXCI6IFwiODhcIiwgXCJIM1wiOiBcIjEyMzRcIiwgXCJINFwiOiBcIjk5OTk5XCIsIFwiSmNcIjogXCI0XCIsIFwiSm1pblwiOiBcIjQwXCIsIFwiSm1heFwiOiBcIjcwXCIsIFwiUzFcIjogXCIxMTZcIiwgXCJTMlwiOiBcIjE3MlwiLCBcImNsaWVudF9wcml2X2tleVwiOiBcInlBbno1VEYrZlQyOEE1dkgwdkdjQzhwVlhxdjVaZlYwKzBQNFJuMXY1SEU9XCIsIFwiY29uZmlnXCI6IFwiW0ludGVyZmFjZV1cXG5Qcml2YXRlS2V5ID0geUFuejVURitmVDI4QTV2SDB2R2NDOHBWWHF2NVpmVjArMFA0Um4xdjVIRT1cXG5BZGRyZXNzID0gMTAuOC4xLjIvMzJcXG5ETlMgPSAxLjEuMS4xXFxuSmMgPSA0XFxuSm1pbiA9IDQwXFxuSm1heCA9IDcwXFxuUzEgPSAxMTZcXG5TMiA9IDE3MlxcbkgxID0gNVxcbkgyID0gODhcXG5IMyA9IDEyMzRcXG5INCA9IDk5OTk5XFxuTVRVID0gMTI4MFxcblxcbltQZWVyXVxcblB1YmxpY0tleSA9IE94NXZEV2ZKOXlma1hjVXVKMlhnS2xRU21HdnZuQkIwcVI5dkszRjJ6VjA9XFxuQWxsb3dlZElQcyA9IDAuMC4wLjAvMCwgOjovMFxcbkVuZHBvaW50ID0gNC4zLjIuMTo0MzIyMVxcblBlcnNpc3RlbnRLZWVwYWxpdmUgPSAyNVxcblwiLCBcImhvc3ROYW1lXCI6IFwiNC4zLjIuMVwiLCBcInBvcnRcIjogNDMyMjF9In19XX0"

    @Test func testParseVPNLinkCompressed() throws {
        let s = try ShareLinkParser.parse("vpn://" + Self.compressedVPNPayload)
        #expect(s.proto == .amnezia)
        #expect(s.name == "Test AWG Server")
        #expect(s.address == "4.3.2.1")
        #expect(s.port == 43221)
        #expect(s.credential == "yAnz5TF+fT28A5vH0vGcC8pVXqv5ZfV0+0P4Rn1v5HE=")
        #expect(s.wgProfile?.peerPublicKey == "Ox5vDWfJ9yfkXcUuJ2XgKlQSmGvvnBB0qR9vK3F2zV0=")
        #expect(s.awg?.junkPackets == 4)
        #expect(s.awg?.junkMin == 40)
        #expect(s.awg?.junkMax == 70)
        #expect(s.awg?.initPadding == 116)
        #expect(s.awg?.responsePadding == 172)
        #expect(s.awg?.header1 == "5")
        #expect(s.awg?.header4 == "99999")
        #expect(s.userData?["wgAddress"] == "10.8.1.2/32")
    }

    @Test func testParseVPNLinkUncompressedFallback() throws {
        let s = try ShareLinkParser.parse("vpn://" + Self.plainVPNPayload)
        #expect(s.proto == .amnezia)
        #expect(s.name == "Test AWG Server")
        #expect(s.address == "4.3.2.1")
        #expect(s.port == 43221)
        #expect(s.credential == "yAnz5TF+fT28A5vH0vGcC8pVXqv5ZfV0+0P4Rn1v5HE=")
    }

    @Test func testParseVPNLinkGarbageThrows() throws {
        // Valid base64 but not an Amnezia envelope.
        #expect(throws: (any Error).self) { try ShareLinkParser.parse("vpn://aGVsbG8gd29ybGQ=") }
        // Not even base64.
        #expect(throws: (any Error).self) { try ShareLinkParser.parse("vpn://@@@") }
    }
}