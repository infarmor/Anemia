import Foundation
import Testing
@testable import LoaderCore

/// Drives the real engine end to end, no root and no network: a local xray
/// VLESS server whose freedom outbound redirects every connection to a local
/// 204 responder, and a client built by XrayConfigBuilder that dials that
/// server by a domain only the `dnsHosts` pin can resolve. Opt-in, since it
/// needs the binary:
///
///     ANEMIA_XRAY_PATH=Resources/xray bash Scripts/test.sh --filter XrayEngineIntegration
struct XrayEngineIntegrationTests {
    nonisolated static let xrayPath = ProcessInfo.processInfo.environment["ANEMIA_XRAY_PATH"]

    enum Variant: String, CaseIterable, Sendable {
        case pinned, pinnedWithFragment, unpinned, xhttp, vlessEncryption
    }

    private static let uuid = "00000000-0000-4000-8000-000000000000"
    private static let pinnedDomain = "pin-test.invalid"

    @Test(.enabled(if: xrayPath != nil), arguments: Variant.allCases)
    func serverDialHonorsTheHostsPin(_ variant: Variant) async throws {
        let xray = try #require(Self.xrayPath)
        let target = try LocalHTTPResponder()
        defer { target.stop() }
        let serverPort = try #require(PortFinder.freePort())
        let socksPort = try #require(PortFinder.freePort())
        let httpPort = try #require(PortFinder.freePort())
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anemia-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var inboundSettings: [String: Any] = ["clients": [["id": Self.uuid]], "decryption": "none"]
        var inboundStream: [String: Any] = ["network": "tcp", "security": "none"]
        var server = ProxyServer(name: "pin", proto: .vless, address: Self.pinnedDomain, port: serverPort,
                                 credential: Self.uuid, network: .tcp, security: .none)
        switch variant {
        case .xhttp:
            inboundStream = ["network": "xhttp", "security": "none",
                             "xhttpSettings": ["path": "/anemia", "mode": "auto"]]
            server.network = .xhttp
            server.path = "/anemia"
            server.xhttpMode = "packet-up"
        case .vlessEncryption:
            let pair = try #require(Self.vlessEncryptionPair(xray), "xray vlessenc produced no key pair")
            inboundSettings["decryption"] = pair.decryption
            server.vlessEncryption = pair.encryption
        default:
            break
        }
        let serverConfig: [String: Any] = [
            "log": ["loglevel": "warning"],
            "inbounds": [[
                "protocol": "vless", "listen": "127.0.0.1", "port": serverPort,
                "settings": inboundSettings,
                "streamSettings": inboundStream
            ] as [String: Any]],
            "outbounds": [["protocol": "freedom",
                           "settings": ["redirect": "127.0.0.1:\(target.port)"]] as [String: Any]]
        ]
        let serverURL = dir.appendingPathComponent("server.json")
        try JSONSerialization.data(withJSONObject: serverConfig).write(to: serverURL)

        var builder = XrayConfigBuilder(socksPort: socksPort, httpPort: httpPort, apiPort: nil)
        if variant != .unpinned { builder.dnsHosts = [Self.pinnedDomain: "127.0.0.1"] }
        let anti: AntiCensorshipOptions = variant == .pinnedWithFragment ? .recommended : .off
        let clientURL = dir.appendingPathComponent("client.json")
        try builder.makeConfigData(server: server, anti: anti).write(to: clientURL)

        let serverProc = try Self.launch(xray, config: serverURL)
        defer { serverProc.terminate() }
        let clientProc = try Self.launch(xray, config: clientURL)
        defer { clientProc.terminate() }
        #expect(await Self.waitUntilListening([serverPort, socksPort]), "engines did not come up")

        // A public TEST-NET address: not in the builder's LAN-direct CIDRs, so
        // it must leave through the proxy outbound — i.e. the server dial.
        let status = await Self.fetchStatus(throughSOCKS: socksPort)
        switch variant {
        case .pinned, .pinnedWithFragment, .xhttp, .vlessEncryption:
            #expect(status == 204, "\(variant) must carry traffic end to end")
        case .unpinned:
            #expect(status == nil, "control: without the pin the domain cannot be dialed")
        }
    }

    nonisolated static let hysteriaPath = ProcessInfo.processInfo.environment["ANEMIA_HYSTERIA_PATH"]

    /// Hysteria 2 through the client config HysteriaConfigBuilder writes: a
    /// local hysteria server (self-signed cert, Salamander obfuscation), the
    /// generated client with its SOCKS bridge, and a request through that
    /// bridge — once with the right certificate pin (must carry traffic) and
    /// once with a wrong one (must refuse to connect). Opt-in:
    ///
    ///     ANEMIA_HYSTERIA_PATH=Resources/hysteria bash Scripts/test.sh --filter XrayEngineIntegration
    @Test(.enabled(if: hysteriaPath != nil), arguments: [true, false])
    func hysteria2BridgeHonorsThePin(_ rightPin: Bool) async throws {
        let hysteria = try #require(Self.hysteriaPath)
        let target = try LocalHTTPResponder()
        defer { target.stop() }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anemia-hy2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let cert = dir.appendingPathComponent("cert.pem").path
        let key = dir.appendingPathComponent("key.pem").path
        try Self.run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-days", "1", "-nodes",
                                          "-keyout", key, "-out", cert, "-subj", "/CN=anemia.test",
                                          "-addext", "subjectAltName=DNS:anemia.test"])
        let fingerprint = try #require(try Self.run("/usr/bin/openssl", ["x509", "-in", cert, "-noout", "-fingerprint", "-sha256"])
            .split(separator: "=").last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        let pin = rightPin ? fingerprint : String(repeating: "00:", count: 31) + "00"

        let serverPort = try #require(Self.freeUDPPort())
        let serverYAML = dir.appendingPathComponent("server.yaml")
        try """
        listen: 127.0.0.1:\(serverPort)
        tls:
          cert: \(cert)
          key: \(key)
        auth:
          type: password
          password: "s3cret"
        obfs:
          type: salamander
          salamander:
            password: "obfs-pass"
        """.write(to: serverYAML, atomically: true, encoding: .utf8)

        let bridgePort = try #require(PortFinder.freePort())
        let link = "hy2://s3cret@127.0.0.1:\(serverPort)/?sni=anemia.test&insecure=1" +
            "&obfs=salamander&obfs-password=obfs-pass&pinSHA256=\(pin)#hy2"
        let server = try ShareLinkParser.parse(link)
        let clientYAML = dir.appendingPathComponent("client.yaml")
        try HysteriaConfigBuilder.makeClientConfig(server: server, socksPort: bridgePort)
            .write(to: clientYAML, atomically: true, encoding: .utf8)

        let serverProc = try Self.launch(hysteria, arguments: ["server", "-c", serverYAML.path])
        defer { serverProc.terminate() }
        try await Task.sleep(for: .milliseconds(400))
        let clientProc = try Self.launch(hysteria, arguments: ["client", "-c", clientYAML.path])
        defer { clientProc.terminate() }

        var status: Int?
        for _ in 0..<20 where status == nil {
            try await Task.sleep(for: .milliseconds(250))
            guard PortFinder.canConnect(bridgePort) else { continue }
            status = await Self.fetchStatus(throughSOCKS: bridgePort, url: "http://127.0.0.1:\(target.port)/")
        }
        if rightPin {
            #expect(status == 204, "the generated hysteria client must carry traffic")
        } else {
            #expect(status == nil, "a wrong certificate pin must stop the connection")
        }
    }

    /// The iOS path: the official hysteria server, and Xray's built-in
    /// Hysteria 2 client from `hysteriaMode = .native` (auth, certificate pin,
    /// Salamander) — reached here through a SOCKS inbound, since the tun
    /// inbound needs root on a Mac. Right pin must carry traffic, wrong pin
    /// must not. Opt-in, needs both binaries:
    ///
    ///     ANEMIA_XRAY_PATH=Resources/xray ANEMIA_HYSTERIA_PATH=Resources/hysteria \
    ///         bash Scripts/test.sh --filter XrayEngineIntegration
    @Test(.enabled(if: xrayPath != nil && hysteriaPath != nil), arguments: [true, false])
    func nativeHysteria2HonorsThePin(_ rightPin: Bool) async throws {
        let xray = try #require(Self.xrayPath)
        let hysteria = try #require(Self.hysteriaPath)
        let target = try LocalHTTPResponder()
        defer { target.stop() }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anemia-hy2-native-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let cert = dir.appendingPathComponent("cert.pem").path
        let key = dir.appendingPathComponent("key.pem").path
        try Self.run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-days", "1", "-nodes",
                                          "-keyout", key, "-out", cert, "-subj", "/CN=anemia.test",
                                          "-addext", "subjectAltName=DNS:anemia.test"])
        let fingerprint = try #require(try Self.run("/usr/bin/openssl", ["x509", "-in", cert, "-noout", "-fingerprint", "-sha256"])
            .split(separator: "=").last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        let pin = rightPin ? fingerprint : String(repeating: "00:", count: 31) + "00"

        let serverPort = try #require(Self.freeUDPPort())
        let serverYAML = dir.appendingPathComponent("server.yaml")
        try """
        listen: 127.0.0.1:\(serverPort)
        tls:
          cert: \(cert)
          key: \(key)
        auth:
          type: password
          password: "s3cret"
        obfs:
          type: salamander
          salamander:
            password: "obfs-pass"
        """.write(to: serverYAML, atomically: true, encoding: .utf8)

        let link = "hy2://s3cret@127.0.0.1:\(serverPort)/?sni=anemia.test&insecure=1" +
            "&obfs=salamander&obfs-password=obfs-pass&pinSHA256=\(pin)#hy2"
        let server = try ShareLinkParser.parse(link)
        let socksPort = try #require(PortFinder.freePort())
        let httpPort = try #require(PortFinder.freePort())
        var builder = XrayConfigBuilder(socksPort: socksPort, httpPort: httpPort, apiPort: nil)
        builder.hysteriaMode = .native
        var config = try builder.makeConfig(server: server, anti: .off)
        // The target is on loopback, which the LAN rule would send direct —
        // past the very proxy under test. Drop that rule here only.
        var routing = try #require(config["routing"] as? [String: Any])
        routing["rules"] = (routing["rules"] as? [[String: Any]])?.filter {
            !(($0["ip"] as? [String])?.contains("127.0.0.0/8") ?? false)
        }
        config["routing"] = routing
        let clientURL = dir.appendingPathComponent("client.json")
        try JSONSerialization.data(withJSONObject: config).write(to: clientURL)

        let serverProc = try Self.launch(hysteria, arguments: ["server", "-c", serverYAML.path])
        defer { serverProc.terminate() }
        try await Task.sleep(for: .milliseconds(400))
        let clientProc = try Self.launch(xray, config: clientURL)
        defer { clientProc.terminate() }
        #expect(await Self.waitUntilListening([socksPort]), "xray did not come up")

        // curl, not URLSession: xray's SOCKS inbound answers before its
        // outbound dials, and with a failing dial URLSession still came back
        // with a status from the loopback target (curl gets none), so the
        // wrong-pin case proved nothing.
        let code = try Self.run("/usr/bin/curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5",
                                                  "--socks5", "127.0.0.1:\(socksPort)",
                                                  "http://127.0.0.1:\(target.port)/"])
        let status = Int(code).flatMap { $0 == 0 ? nil : $0 }
        if rightPin {
            #expect(status == 204, "xray's built-in hysteria client must carry traffic")
        } else {
            #expect(status == nil, "a wrong certificate pin must stop the connection")
        }
    }

    /// The whole iOS engine config — tun inbound, in-process stats, file log,
    /// DNS hijack — must pass the engine's own config build. Opt-in.
    @Test(.enabled(if: xrayPath != nil), arguments: [ProxyProtocol.vless, .hysteria2])
    func packetTunnelConfigPassesTheEngineCheck(_ proto: ProxyProtocol) throws {
        let xray = try #require(Self.xrayPath)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anemia-tun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var builder = XrayConfigBuilder(apiPort: nil, bufferSizeKB: 4)
        builder.inboundMode = .packetTunnel(mtu: 1500)
        builder.hysteriaMode = .native
        builder.collectsStats = true
        builder.dnsQueryStrategy = "UseIPv4"
        builder.logFile = dir.appendingPathComponent("engine.log").path
        builder.dnsHosts = ["srv.example.com": "192.0.2.10"]
        builder.bypass = SplitTunnelParser.parse(["ru", "vk.com", "203.0.113.0/24"]).entries
        builder.bypassResolver = "77.88.8.8"
        let server: ProxyServer
        if proto == .hysteria2 {
            server = try ShareLinkParser.parse(
                "hy2://pw@192.0.2.10:443/?sni=srv.example.com&obfs=salamander&obfs-password=x&mport=20000-50000#hy")
        } else {
            server = ProxyServer(name: "r", proto: .vless, address: "srv.example.com", port: 443,
                                 credential: Self.uuid, network: .tcp, security: .reality,
                                 sni: "www.microsoft.com", fingerprint: "chrome",
                                 realityPublicKey: "SmkAOaLHaacpWxQyVNlEw1Y4qjxc9KBQNWmFPDvBjk8",
                                 realityShortId: "abcd", flow: "xtls-rprx-vision")
        }
        let url = dir.appendingPathComponent("tun.json")
        try builder.makeConfigData(server: server, anti: .recommended).write(to: url)

        // `run -test` really creates the tun inbound. Hand it a descriptor
        // the way the iOS wrapper does (xray.tun.fd), here a pipe on stdin —
        // otherwise it would try to open a utun, which needs root.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: xray)
        proc.arguments = ["run", "-test", "-c", url.path]
        proc.environment = ["XRAY_TUN_FD": "0"]
        let input = Pipe()
        proc.standardInput = input
        let output = Pipe()
        proc.standardOutput = output
        proc.standardError = output
        try proc.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proc.waitUntilExit()
        #expect(text.contains("Configuration OK"), "engine rejected the iOS config:\n\(text)")
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proc.waitUntilExit()
        return output
    }

    private static func freeUDPPort() -> Int? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }) == 0,
              withUnsafeMutablePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }) == 0
        else { return nil }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    /// The X25519-authenticated decryption/encryption pair `xray vlessenc` prints first.
    private static func vlessEncryptionPair(_ binary: String) -> (decryption: String, encryption: String)? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["vlessenc"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proc.waitUntilExit()
        func first(_ key: String) -> String? {
            for line in text.split(separator: "\n") where line.contains("\"\(key)\"") {
                let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
                if parts.count >= 4 { return String(parts[3]) }
            }
            return nil
        }
        guard let decryption = first("decryption"), let encryption = first("encryption") else { return nil }
        return (decryption, encryption)
    }

    private static func launch(_ binary: String, config: URL) throws -> Process {
        try launch(binary, arguments: ["run", "-c", config.path])
    }

    private static func launch(_ binary: String, arguments: [String]) throws -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        return proc
    }

    private static func waitUntilListening(_ ports: [Int]) async -> Bool {
        for _ in 0..<300 {
            if ports.allSatisfy({ PortFinder.canConnect($0) }) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private static func fetchStatus(throughSOCKS port: Int) async -> Int? {
        await fetchStatus(throughSOCKS: port, url: "http://203.0.113.10/generate_204")
    }

    private static func fetchStatus(throughSOCKS port: Int, url: String) async -> Int? {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.connectionProxyDictionary = ["SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": port]
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: url),
              let (_, response) = try? await session.data(from: url) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }
}

/// A loopback listener answering every connection with an empty 204.
private final class LocalHTTPResponder: @unchecked Sendable {
    struct SetupFailed: Error {}

    let port: Int
    private let fd: Int32

    init() throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SetupFailed() }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let listener = fd
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, len) }
        }
        guard bound == 0, listen(listener, 16) == 0 else { Darwin.close(listener); throw SetupFailed() }
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &len) }
        }
        port = Int(UInt16(bigEndian: addr.sin_port))
        Thread.detachNewThread {
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                var request = [UInt8](repeating: 0, count: 4096)
                _ = read(client, &request, request.count)
                let reply = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                _ = reply.withCString { write(client, $0, strlen($0)) }
                Darwin.close(client)
            }
        }
    }

    func stop() {
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}
