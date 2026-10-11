import AnemiaEngine
import Foundation
import LoaderCore

/// Real checks through the engine (Engine/probe.go): a request that travels
/// through the proxy, where a ping only reaches the server. Both the app
/// (while the VPN is off) and the tunnel extension (while it is on) run them,
/// each with its own copy of the engine.
enum EngineProbe {
    /// Google's connectivity check: tiny, served everywhere, answers 204.
    static let url = "https://www.gstatic.com/generate_204"

    struct Outcome: Codable, Hashable {
        var id: UUID
        /// Milliseconds to the response headers; nil when the request failed.
        var ms: Int?
        var error: String?
    }

    /// One server to check, with the masking to check it with.
    struct Item: Codable {
        var server: ProxyServer
        var masking: MaskingProfile
    }

    /// Blocking: runs every server, `concurrency` at a time. Call it off the
    /// main thread.
    static func run(_ items: [Item], timeout: TimeInterval = 6, concurrency: Int) -> [Outcome] {
        var requests: [[String: String]] = []
        var outcomes: [Outcome] = []
        for item in items {
            let server = item.server
            do {
                let config = try ProbeConfig.json(for: server, masking: item.masking)
                requests.append(["id": server.id.uuidString, "config": config])
            } catch {
                outcomes.append(Outcome(id: server.id, ms: nil, error: error.localizedDescription))
            }
        }
        guard !requests.isEmpty,
              let payload = try? JSONSerialization.data(withJSONObject: requests),
              let text = String(data: payload, encoding: .utf8)
        else { return outcomes }

        let reply = text.withCString { requestText in
            url.withCString { urlText in
                AnemiaProbe(UnsafeMutablePointer(mutating: requestText), UnsafeMutablePointer(mutating: urlText),
                            Int32(timeout * 1000), Int32(max(concurrency, 1)))
            }
        }
        guard let reply else { return outcomes }
        defer { AnemiaFree(reply) }

        struct Raw: Decodable {
            var id: String
            var ms: Int
            var error: String?
        }
        let raw = (try? JSONDecoder().decode([Raw].self, from: Data(String(cString: reply).utf8))) ?? []
        for item in raw {
            guard let id = UUID(uuidString: item.id) else { continue }
            outcomes.append(Outcome(id: id, ms: item.ms >= 0 ? item.ms : nil, error: item.error))
        }
        return outcomes
    }

    /// The same, on a background thread.
    static func runDetached(_ items: [Item], timeout: TimeInterval = 6, concurrency: Int) async -> [Outcome] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: run(items, timeout: timeout, concurrency: concurrency))
            }
        }
    }

    /// Whether the running tunnel carries traffic: milliseconds for one
    /// request through it, nil when the request failed or no Xray runs.
    /// Blocking — и не с кооперативного пула: до 8 с висящей нити там ровно
    /// те несколько, что есть на iPhone, и встает вместе с этим всё, что
    /// крутится на нём же (`ServerPinger.run`, `EngineProbe.runDetached`).
    static func checkActive(timeout: TimeInterval = 8) -> Int? {
        let ms = url.withCString { AnemiaCheckActive(UnsafeMutablePointer(mutating: $0), Int32(timeout * 1000)) }
        return ms > 0 ? Int(ms) : nil
    }

    /// То же на отдельной очереди — как `runDetached` для пакетной проверки.
    static func checkActiveDetached(timeout: TimeInterval = 8) async -> Int? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: checkActive(timeout: timeout))
            }
        }
    }
}

/// The engine config for a real check of one server: the tunnel's own
/// config with the tunnel taken out, so the check goes exactly the way the
/// traffic would.
enum ProbeConfig {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// WireGuard-family servers have no dialer to check through: they only
    /// get a ping.
    static func supports(_ server: ProxyServer) -> Bool {
        server.runsOnIOSEngine && !server.proto.isWireGuardFamily
    }

    static func json(for original: ProxyServer, masking: MaskingProfile) throws -> String {
        guard supports(original) else {
            throw Failure(message: "Этот протокол проверяется только пингом")
        }
        var server = original
        var builder = XrayConfigBuilder(apiPort: nil, bufferSizeKB: 4)
        builder.inboundMode = .packetTunnel(mtu: 1500)
        builder.hysteriaMode = .native
        builder.collectsStats = false
        // Resolved here, as the tunnel does before it starts.
        let bare = server.address.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if !DirectResolver.isIPv4(bare), !bare.contains(":") {
            guard let endpoint = DirectResolver.ipv4(bare).first else {
                throw Failure(message: "Не удалось узнать адрес сервера")
            }
            if server.proto.isHysteriaFamily {
                if server.sni?.isEmpty ?? true { server.sni = server.address }
                server.address = endpoint
            } else {
                builder.dnsHosts = [server.address: endpoint]
            }
        }
        let text = try builder.makeConfigString(server: server, anti: masking.options)
        guard var config = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw Failure(message: "Не удалось собрать конфиг")
        }
        config["inbounds"] = [Any]()
        config["log"] = ["loglevel": "none"]
        let data = try JSONSerialization.data(withJSONObject: config)
        return String(decoding: data, as: UTF8.self)
    }
}

extension ProxyServer {
    /// Everything but Hysteria 1, which the iOS engine lacks.
    var runsOnIOSEngine: Bool { proto != .hysteria }
}
