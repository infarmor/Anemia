import Foundation
import LoaderCore
import os

/// "Check Servers": one real HTTPS request through each server, by a
/// throwaway engine that exists for that request alone. Unlike a ping it
/// catches the servers that answer the handshake but carry nothing — a
/// wrong key, a blocked path, DPI that lets the handshake through and kills
/// the rest.
///
/// WireGuard-family and Hysteria servers keep their ping: their engines run
/// through the helper or a separate client, not a throwaway xray.
enum ProxyCheck {
    enum Verdict: Equatable, Sendable {
        /// Milliseconds for one request through the server.
        case works(Int)
        /// Answers, but no request got through — why, in a few words.
        case broken(String)

        var works: Bool {
            if case .works = self { return true }
            return false
        }
    }

    struct Item: Sendable {
        let server: ProxyServer
        let anti: AntiCensorshipOptions
    }

    static let target = URL(string: "https://www.gstatic.com/generate_204")!

    static func supports(_ server: ProxyServer) -> Bool {
        !server.proto.isWireGuardFamily && !server.proto.isHysteriaFamily
    }

    /// Masking shapes the TCP handshake: stronger masking can get a
    /// DPI-blocked TCP transport through, not QUIC (mKCP, QUIC) ones.
    static func maskable(_ server: ProxyServer) -> Bool {
        switch server.proto {
        case .vless, .vmess, .trojan, .shadowsocks:
            return server.network != .kcp && server.network != .quic
        default:
            return false
        }
    }

    /// Checks `items`, `concurrency` at a time; `found` hears each verdict
    /// as it lands. `dialerInterface` pins the engines' server dials to the
    /// physical interface (nil: they follow the routes — through the running
    /// tunnel, when its kill switch allows nothing else).
    static func run(_ items: [Item], binary: URL, dialerInterface: String?, concurrency: Int = 3,
                    found: @escaping @Sendable (UUID, Verdict) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var pending = items.makeIterator()
            func enqueue() {
                guard let item = pending.next() else { return }
                group.addTask {
                    let verdict = await check(item, binary: binary, dialerInterface: dialerInterface)
                    await found(item.server.id, verdict)
                }
            }
            for _ in 0..<max(concurrency, 1) { enqueue() }
            for await _ in group {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                enqueue()
            }
        }
    }

    // MARK: - One server

    static func check(_ item: Item, binary: URL, dialerInterface: String?) async -> Verdict {
        let server = item.server
        let socks = PortFinder.pick(preferred: Int.random(in: 31_000...44_000))
        let http = PortFinder.pick(preferred: socks + 1, exclude: [socks])
        var builder = XrayConfigBuilder(socksPort: socks, httpPort: http, logLevel: "warning",
                                        enableSniffing: false, apiPort: nil,
                                        dialerInterface: dialerInterface, blockQUIC: false,
                                        hijackDNS: false, bufferSizeKB: 16)
        // Like the real engine: the server's name is resolved here and pinned,
        // so the engine's own lookup can't wander into a tunnel.
        if !DirectResolver.isIPv4(server.address),
           let ip = await resolve(server.address) {
            builder.dnsHosts[server.address] = ip
        }
        let config: Data
        do {
            config = try builder.makeConfigData(server: server, anti: item.anti)
        } catch {
            return .broken("Unsupported configuration")
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("anemia-check-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        guard (try? config.write(to: file, options: .atomic)) != nil else {
            return .broken("Couldn't write the engine configuration")
        }

        let engine = Engine(binary: binary, config: file)
        guard engine.start() else { return .broken("The engine didn't start") }
        defer { engine.stop() }
        guard await engine.waitForPort(socks) else {
            return .broken(engine.exited ? "The engine rejected the server" : "The engine didn't start")
        }

        let configuration = LocalProxy.sessionConfiguration(LocalProxy(port: socks))
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let start = Date()
        do {
            var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.httpMethod = "GET"
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<400).contains(status) else { return .broken("Unexpected answer (HTTP \(status))") }
            return .works(max(1, Int(Date().timeIntervalSince(start) * 1000)))
        } catch {
            return .broken(reason(error, log: engine.log))
        }
    }

    /// The failure in a few words, from the engine's own complaint when it
    /// has one.
    static func reason(_ error: Error, log: String) -> String {
        let text = log.lowercased()
        if text.contains("x509") || text.contains("certificate") || text.contains("tls: ") {
            return "TLS error"
        }
        if text.contains("connection reset") || text.contains("eof") {
            return "Server drops the connection"
        }
        if (error as? URLError)?.code == .timedOut || text.contains("timeout") || text.contains("i/o timeout") {
            return "No response through the proxy"
        }
        return "Doesn't carry traffic"
    }

    /// Kills every throwaway engine still running: at quit, a check in
    /// flight would leave them behind, each holding a port.
    static func stopAll() {
        for (pid, path) in Engine.running.withLock({ $0 }) {
            // Re-identify before signalling. `running` drops a pid only in
            // stop(), so an engine that died on its own while its check was
            // still awaiting leaves the pid here — and after the reap the
            // kernel hands that number to the next fork, which would take a
            // SIGKILL meant for a throwaway xray.
            guard EngineProcess.pid(pid, isExecutable: path) else { continue }
            kill(pid, SIGKILL)
        }
    }

    /// getaddrinfo keeps no deadline of its own.
    private static func resolve(_ host: String) async -> String? {
        await XrayController.withTimeout(seconds: 3, fallback: nil) { DirectResolver.ipv4(host).first }
    }
}

/// One throwaway xray process: started, waited on, stopped. Its output is
/// kept (the last few KB) to tell why a check failed.
private final class Engine: @unchecked Sendable {
    /// Every engine started and not yet stopped, with the binary it was
    /// launched from — `stopAll` re-checks that the pid still runs it
    /// (ProxyCheck.stopAll).
    static let running = OSAllocatedUnfairLock(initialState: [pid_t: String]())

    private let process = Process()
    private let binaryPath: String
    private let lock = NSLock()
    private var output = ""

    init(binary: URL, config: URL) {
        process.executableURL = binary
        // Stored resolved, the way `proc_pidpath` reports it — see
        // EngineProcess.pid(_:isExecutable:).
        binaryPath = EngineProcess.canonical(binary.path)
        process.arguments = ["run", "-c", config.path]
        process.qualityOfService = .utility
    }

    var exited: Bool { !process.isRunning }

    var log: String { lock.withLock { output } }

    func start() -> Bool {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            self.lock.withLock {
                self.output += text
                if self.output.count > 8_000 { self.output = String(self.output.suffix(4_000)) }
            }
        }
        do {
            try process.run()
            let pid = process.processIdentifier
            Self.running.withLock { $0[pid] = binaryPath }
            return true
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return false
        }
    }

    /// Until the SOCKS inbound listens, up to 4 s; false when it never did
    /// or the engine died first.
    func waitForPort(_ port: Int) async -> Bool {
        for _ in 0..<40 {
            if !process.isRunning { return false }
            if !PortFinder.isFree(port) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    func stop() {
        let pid = process.processIdentifier
        Self.running.withLock { _ = $0.removeValue(forKey: pid) }
        guard process.isRunning else { return }
        process.terminate()
        // Held until then: a check that returned doesn't wait for the exit.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [self] in
            if self.process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// Server IDs a check found working, gathered from concurrent checks.
final class RescueList: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<UUID> = []

    func add(_ id: UUID) { lock.withLock { _ = ids.insert(id) } }
    func contains(_ id: UUID) -> Bool { lock.withLock { ids.contains(id) } }
}
