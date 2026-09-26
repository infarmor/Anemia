import Foundation
import Testing
@testable import LoaderCore

/// Transports and protocol options the bundled engines run and real panels
/// emit — each checked from link to engine config.
struct ProtocolCoverageTests {
    private let uuid = "00000000-0000-4000-8000-000000000000"

    private func outbound(_ server: ProxyServer) throws -> [String: Any] {
        let data = try XrayConfigBuilder().makeConfigData(server: server, anti: .off)
        let cfg = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let outs = try #require(cfg["outbounds"] as? [[String: Any]])
        return try #require(outs.first { $0["tag"] as? String == "proxy" })
    }

    // MARK: XHTTP

    @Test func vlessRealityOverXHTTP() throws {
        let extra = #"{"xmux":{"maxConcurrency":"16-32"}}"#
        let link = "vless://\(uuid)@edge.example.com:443?type=xhttp&security=reality" +
            "&pbk=Wo59E9xfEY78HbBug86yvhiP92YAHEUDnuvYpt56ajk&sni=www.microsoft.com&fp=chrome" +
            "&path=%2Fanemia&host=cdn.example.com&mode=packet-up" +
            "&extra=\(extra.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)#XHTTP"
        let s = try ShareLinkParser.parse(link)
        #expect(s.network == .xhttp)
        #expect(s.path == "/anemia")
        #expect(s.host == "cdn.example.com")
        #expect(s.xhttpMode == "packet-up")
        #expect(s.xhttpExtra == extra)

        let stream = try #require(try outbound(s)["streamSettings"] as? [String: Any])
        #expect(stream["network"] as? String == "xhttp")
        let xhttp = try #require(stream["xhttpSettings"] as? [String: Any])
        #expect(xhttp["path"] as? String == "/anemia")
        #expect(xhttp["mode"] as? String == "packet-up")
        let xmux = (xhttp["extra"] as? [String: Any])?["xmux"] as? [String: Any]
        #expect(xmux?["maxConcurrency"] as? String == "16-32")
    }

    @Test func splitHTTPIsXHTTP() throws {
        let s = try ShareLinkParser.parse("vless://\(uuid)@h.example.com:443?type=splithttp&security=tls&path=%2Fx")
        #expect(s.network == .xhttp)
    }

    @Test func xhttpMisconfigurationFailsAtBuild() throws {
        var s = ProxyServer(name: "x", proto: .vless, address: "h.example.com", port: 443,
                            credential: uuid, network: .xhttp, security: .tls)
        s.xhttpMode = "nonsense"
        #expect(throws: ConfigBuilderError.invalidXHTTPMode("nonsense")) {
            try XrayConfigBuilder().makeConfigData(server: s, anti: .off)
        }
        s.xhttpMode = nil
        s.xhttpExtra = "{not json"
        #expect(throws: ConfigBuilderError.invalidXHTTPExtra) {
            try XrayConfigBuilder().makeConfigData(server: s, anti: .off)
        }
    }

    @Test func xhttpSkipsMuxCool() throws {
        var anti = AntiCensorshipOptions.off
        anti.muxEnabled = true
        let s = ProxyServer(name: "x", proto: .vless, address: "h.example.com", port: 443,
                            credential: uuid, network: .xhttp, security: .tls)
        let cfg = try XrayConfigBuilder().makeConfig(server: s, anti: anti)
        let proxy = (cfg["outbounds"] as? [[String: Any]])?.first { $0["tag"] as? String == "proxy" }
        #expect(proxy?["mux"] == nil)
    }

    // MARK: VLESS Encryption

    @Test func vlessEncryptionReachesTheUser() throws {
        let enc = "mlkem768x25519plus.native.0rtt.gwuQdtHzmU9EpxKijRKeeUzXuvW5Fz6nwXoZ296pdAw"
        let s = try ShareLinkParser.parse("vless://\(uuid)@h.example.com:443?encryption=\(enc)&security=tls&type=tcp")
        #expect(s.vlessEncryption == enc)
        let settings = try #require(try outbound(s)["settings"] as? [String: Any])
        let user = ((settings["vnext"] as? [[String: Any]])?.first?["users"] as? [[String: Any]])?.first
        #expect(user?["encryption"] as? String == enc)

        let plain = try ShareLinkParser.parse("vless://\(uuid)@h.example.com:443?encryption=none&security=tls")
        #expect(plain.vlessEncryption == nil)
    }

    // MARK: Hysteria 2 port hopping

    @Test func hysteria2MultiPortAuthority() throws {
        let s = try ShareLinkParser.parse("hysteria2://secret@hy.example.com:443,20000-50000/?sni=hy.example.com#HY")
        #expect(s.address == "hy.example.com")
        #expect(s.port == 443)
        #expect(s.name == "HY")
        #expect(s.userData?["portHopping"] == "443,20000-50000")
        let yaml = try HysteriaConfigBuilder.makeClientConfig(server: s, socksPort: 21180)
        #expect(yaml.contains(#"server: "hy.example.com:443,20000-50000""#))
        #expect(HysteriaConfigBuilder.validate(server: s) == [])
    }

    @Test func hysteria2MportParameterWidensThePort() throws {
        let s = try ShareLinkParser.parse("hy2://secret@hy.example.com:443?mport=20000-30000")
        #expect(HysteriaConfigBuilder.portSpec(for: s) == "443,20000-30000")
        let ipv6 = try ShareLinkParser.parse("hy2://secret@[2001:db8::1]:8443,9000-9100")
        #expect(ipv6.address == "2001:db8::1")
        #expect(ipv6.port == 8443)
        #expect(try HysteriaConfigBuilder.makeClientConfig(server: ipv6, socksPort: 1)
            .contains(#"server: "[2001:db8::1]:8443,9000-9100""#))
    }

    /// The hysteria client reads `tls.pinSHA256`; the old `pinnedSHA256`
    /// spelling was silently ignored, so a link's pin never took effect.
    @Test func hysteriaPinUsesTheClientsFieldName() throws {
        let s = try ShareLinkParser.parse("hy2://secret@hy.example.com:443/?pinSHA256=AB:CD&insecure=1")
        let yaml = try HysteriaConfigBuilder.makeClientConfig(server: s, socksPort: 1080)
        #expect(yaml.contains(#"  pinSHA256: "AB:CD""#))
        #expect(!yaml.contains("pinnedSHA256"))
        #expect(yaml.contains("  insecure: true"))
    }

    @Test func portSpecValidation() {
        #expect(HysteriaConfigBuilder.isValidPortSpec("443"))
        #expect(HysteriaConfigBuilder.isValidPortSpec("443,20000-50000,60000"))
        #expect(!HysteriaConfigBuilder.isValidPortSpec("50000-20000"))
        #expect(!HysteriaConfigBuilder.isValidPortSpec("0-10"))
        #expect(!HysteriaConfigBuilder.isValidPortSpec("443,,80"))
        #expect(!HysteriaConfigBuilder.isValidPortSpec("abc"))
        #expect(!HysteriaConfigBuilder.isValidPortSpec("70000"))
    }

    // MARK: Shadowsocks 2022

    @Test func shadowsocks2022PlainUserinfo() throws {
        let key = "bm9wZW5vcGVub3Blbm9wZW5vcGVub3Blbm9wZW5vcGU="
        let link = "ss://2022-blake3-aes-256-gcm:\(key.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)@ss.example.com:8388#SS22"
        let s = try ShareLinkParser.parse(link)
        #expect(s.method == "2022-blake3-aes-256-gcm")
        #expect(s.credential == key)
        #expect(s.port == 8388)
    }
}
