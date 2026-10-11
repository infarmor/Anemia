import AnemiaEngine
import Foundation

/// Swift face of the Go engine (Engine/engine.go): Xray-core and AmneziaWG in
/// one runtime, one of them running at a time.
enum Engine {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// `AnemiaStatus()` JSON.
    struct Status: Decodable {
        var engine: String
        var uptime: Double
        var up: Int64
        var down: Int64
        /// Unix time of AmneziaWG's latest handshake, 0 before the first.
        var handshake: Int64
        var heap: UInt64
        var sys: UInt64
        var goroutines: Int
        /// Keys the answer didn't carry. Empty in a matched pair of versions.
        var missingKeys: [String] = []

        enum CodingKeys: String, CodingKey, CaseIterable {
            case engine, uptime, up, down, handshake, heap, sys, goroutines
        }

        /// Field by field, not all-or-nothing: every consumer reads
        /// `status?.up ?? 0`, so a whole-document decode failure used to turn a
        /// renamed key into permanent zeros in the UI — and, worse, into
        /// `status == nil` at the AmneziaWG health check, which silently stopped
        /// auto-switch. Now the surviving fields survive, and the ones that went
        /// missing are named in the log.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            var missing: [String] = []
            func read<T: Decodable>(_ type: T.Type, _ key: CodingKeys, _ fallback: T) -> T {
                // `try?` over `decodeIfPresent`: absent, null and wrong-typed all
                // mean "the answer didn't carry it" — and all three are worth a
                // line in the log, because that is how a renamed key gets noticed
                // instead of quietly reading as zero forever.
                guard let value: T = try? c.decodeIfPresent(type, forKey: key) else {
                    missing.append(key.rawValue)
                    return fallback
                }
                return value
            }
            engine = read(String.self, .engine, "?")
            uptime = read(Double.self, .uptime, 0)
            up = read(Int64.self, .up, 0)
            down = read(Int64.self, .down, 0)
            handshake = read(Int64.self, .handshake, 0)
            heap = read(UInt64.self, .heap, 0)
            sys = read(UInt64.self, .sys, 0)
            goroutines = read(Int.self, .goroutines, 0)
            missingKeys = missing
        }
    }

    static func startXray(config: String, tunnelFD: Int32) throws {
        try check(config.withCString { AnemiaStartXray(UnsafeMutablePointer(mutating: $0), tunnelFD) })
    }

    static func startAWG(uapi: String, tunnelFD: Int32) throws {
        try check(uapi.withCString { AnemiaStartAWG(UnsafeMutablePointer(mutating: $0), tunnelFD) })
    }

    static func stop() {
        AnemiaStop()
    }

    /// Wi-Fi ↔ cellular: AmneziaWG rebinds its sockets.
    static func networkChanged() {
        AnemiaNetworkChanged()
    }

    /// The utun descriptor NetworkExtension opened for this process.
    static var tunnelFD: Int32? {
        let fd = AnemiaFindTunnelFD()
        return fd >= 0 ? fd : nil
    }

    static var status: Status? {
        guard let json = take(AnemiaStatus()) else { return nil }
        guard let decoded = try? JSONDecoder().decode(Status.self, from: Data(json.utf8)) else { return nil }
        // An answer that carried none of the keys isn't a status; keeping it
        // would show the traffic row at zero and call the AWG peer dead.
        return decoded.missingKeys.count == Status.CodingKeys.allCases.count ? nil : decoded
    }

    static var version: String {
        take(AnemiaVersion()) ?? "?"
    }

    static func setMemoryLimit(bytes: Int64) {
        AnemiaSetMemoryLimit(bytes)
    }

    /// A fresh engine.log (and crash.log for Go panics) in `directory`.
    static func setLogDirectory(_ directory: URL) throws {
        try check(directory.path.withCString { AnemiaSetLogDirectory(UnsafeMutablePointer(mutating: $0)) })
    }

    private static func check(_ error: UnsafeMutablePointer<CChar>?) throws {
        if let message = take(error) { throw Failure(message: message) }
    }

    /// Copies, then frees, a string the engine returned.
    private static func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { AnemiaFree(pointer) }
        return String(cString: pointer)
    }
}
