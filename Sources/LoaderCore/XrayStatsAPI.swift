import Foundation
import Network

/// One counter from Xray's Stats API.
public struct XrayStat: Sendable, Equatable {
    public let name: String
    public let value: Int64
}

/// Native gRPC-over-h2c client for Xray's `StatsService.QueryStats`.
///
/// Replaces the per-poll `xray api statsquery` fork: every sample used to
/// spawn the whole ~28 MB engine binary just to read two counters. This
/// speaks the exact minimal subset of HTTP/2 one unary RPC needs — client
/// preface, SETTINGS (+WINDOW_UPDATE), HPACK literal headers without
/// indexing or Huffman, a DATA frame, and a frame-parse loop — plus a
/// protobuf varint walk of `QueryStatsResponse`. (NWProtocolHTTP2 no longer
/// exists in the macOS 27 SDK, hence the hand-rolled frames.)
///
/// One blocking call per invocation; run it off the main actor. `nil` means
/// the RPC did not complete within `timeout` (connection refused, RST,
/// GOAWAY, slow peer) — callers fall back to the CLI path.
public enum XrayStatsAPI {

    /// Query cumulative counter values. `pattern` is the protobuf query
    /// pattern (e.g. `"outbound>>>proxy>>>"`); nil queries every counter —
    /// keep it narrow, the response fits the default flow-control window.
    public static func query(
        host: String = "127.0.0.1",
        port: UInt16,
        pattern: String?,
        timeout: TimeInterval = 6
    ) -> [XrayStat]? {
        let session = Session(host: host, port: port, pattern: pattern)
        let result = session.run(timeout: timeout)
        guard result.count >= 5, result.first == 0x00 else { return nil }

        // Strip the 5-byte gRPC frame prefix (compression flag + length).
        let plen = Int(result[result.index(after: result.startIndex)...].prefix(4)
            .reduce(0) { $0 << 8 | Int($1) })
        let proto = result.subdata(in: result.index(result.startIndex, offsetBy: 5)..<result.endIndex)
        guard plen == proto.count else { return nil }

        return parseProtobuf(proto)
    }

    /// One RPC's connection state. All mutation is lock-guarded and the class
    /// is handed across NWConnection's queues, so it's @unchecked Sendable.
    private final class Session: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var message = Data()
        private var failure: String?
        private var finished = false
        private let done = DispatchSemaphore(value: 0)
        private let conn: NWConnection
        private let request: Data

        init(host: String, port: UInt16, pattern: String?) {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port) ?? 0,
                using: NWParameters(tls: nil, tcp: tcp)
            )
            request = XrayStatsAPI.requestBytes(port: port, pattern: pattern)
        }

        func run(timeout: TimeInterval) -> Data {
            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.conn.send(content: self.request,
                                   completion: .contentProcessed { [weak self] error in
                        if let error { self?.finish("send: \(error)") }
                    })
                case .failed(let e): self.finish("connect: \(e)")
                default: break
                }
            }
            conn.start(queue: DispatchQueue(label: "loader.statsapi"))
            readMore()
            if done.wait(timeout: .now() + timeout) == .timedOut { finish("timeout") }
            conn.cancel()
            lock.lock()
            defer { lock.unlock() }
            return failure == nil ? message : Data()
        }

        private func finish(_ error: String?) {
            lock.lock()
            // The FIRST call decides the verdict. `failure == nil` *is* success
            // for the caller below, so a second call — the "eof" that follows a
            // complete response delivered in the same read, or the cancel
            // handler racing the timeout path — used to overwrite a parsed
            // answer with an error string, and the poll fell back to the 28 MB
            // CLI fork even though the stats had arrived.
            let alreadyDone = finished
            if !alreadyDone { failure = error }
            finished = true
            lock.unlock()
            if !alreadyDone { done.signal() }
        }

        private func handleFrame(_ payload: Data, type: UInt8, flags: UInt8) {
            switch type {
            case 0x4: // SETTINGS — ACK anything that isn't already an ACK
                if flags & 0x1 == 0 {
                    conn.send(content: XrayStatsAPI.frame(type: 0x4, flags: 0x1, stream: 0, payload: Data()),
                              completion: .contentProcessed { _ in })
                }
            case 0x0: // DATA
                lock.lock(); message.append(payload); lock.unlock()
                if flags & 0x1 != 0 { finish(nil) }
            case 0x1, 0x9: // HEADERS (initial + trailers), CONTINUATION — skip
                if flags & 0x1 != 0 { finish(nil) }
            case 0x3: finish("RST_STREAM")
            case 0x7: finish("GOAWAY")
            default: break // PING, WINDOW_UPDATE, …
            }
        }

        private func readMore() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let error { self.finish("recv: \(error)") }
                if let data {
                    self.lock.lock(); self.buffer.append(data); self.lock.unlock()
                    while true {
                        self.lock.lock()
                        guard self.buffer.count >= 9 else { self.lock.unlock(); break }
                        let i0 = self.buffer.startIndex
                        let n = (Int(self.buffer[i0]) << 16) | (Int(self.buffer[i0 + 1]) << 8) | Int(self.buffer[i0 + 2])
                        guard self.buffer.count >= 9 + n else { self.lock.unlock(); break }
                        let payload = self.buffer.subdata(in: (i0 + 9)..<(i0 + 9 + n))
                        let type = self.buffer[i0 + 3], flags = self.buffer[i0 + 4]
                        self.buffer.removeSubrange(i0..<(i0 + 9 + n))
                        self.lock.unlock()
                        self.handleFrame(payload, type: type, flags: flags)
                    }
                }
                if isComplete { self.finish("eof") }
                else { self.readMore() }
            }
        }
    }

    // MARK: - Wire format

    /// Preface + SETTINGS + large WINDOW_UPDATE + HEADERS + DATA(END_STREAM).
    /// The WINDOW_UPDATE raises the connection flow window past any realistic
    /// response so the parse loop never stalls waiting for credit we never
    /// grant.
    public static func requestBytes(port: UInt16, pattern: String?) -> Data {
        var out = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
        out += frame(type: 0x4, flags: 0, stream: 0, payload: Data())              // SETTINGS (empty)
        let wu = Data([0x00, 0x0F, 0x42, 0x40])                                    // +1 MiB
        out += frame(type: 0x8, flags: 0, stream: 0, payload: wu)
        var headers = Data()
        headers += header(":method", "POST")
        headers += header(":scheme", "http")
        headers += header(":path", "/xray.app.stats.command.StatsService/QueryStats")
        headers += header(":authority", "127.0.0.1:\(port)")
        headers += header("content-type", "application/grpc")
        headers += header("te", "trailers")
        headers += header("user-agent", "anemia-stats/1")
        out += frame(type: 0x1, flags: 0x4, stream: 1, payload: headers)           // HEADERS + END_HEADERS
        // QueryStatsRequest { string pattern = 1 } — empty message when nil.
        var body = Data()
        if let pattern {
            let bytes = Array(pattern.utf8)
            body.append(0x0A)                                                      // field 1, wire 2
            encodeVarint(Int64(bytes.count), into: &body)
            body.append(contentsOf: bytes)
        }
        var grpc = Data([0x00])                                                // uncompressed
        var n = Int32(body.count).bigEndian                                    // gRPC: fixed 4-byte BE length
        grpc.append(contentsOf: withUnsafeBytes(of: &n) { Data($0) })
        grpc += body
        out += frame(type: 0x0, flags: 0x1, stream: 1, payload: grpc)          // DATA + END_STREAM
        return out
    }

    private static func encodeVarint(_ v0: Int64, into d: inout Data) {
        var v = UInt64(bitPattern: v0)
        while true {
            var b = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { b |= 0x80 }
            d.append(b)
            if v == 0 { break }
        }
    }

    /// 24-bit big-endian length + type + flags + 32-bit stream id.
    public static func frame(type: UInt8, flags: UInt8, stream: UInt32, payload: Data) -> Data {
        var d = Data()
        let n = payload.count
        d.append(UInt8((n >> 16) & 0xFF)); d.append(UInt8((n >> 8) & 0xFF)); d.append(UInt8(n & 0xFF))
        d.append(type); d.append(flags)
        var s = stream.bigEndian
        d.append(contentsOf: withUnsafeBytes(of: &s) { Data($0) })
        d.append(payload)
        return d
    }

    /// HPACK literal header field without indexing, new name, no Huffman —
    /// a stateless encoding both sides can decode without table bookkeeping.
    public static func header(_ name: String, _ value: String) -> Data {
        func str(_ s: String) -> Data {
            let b = Array(s.utf8)
            var d = Data()
            if b.count < 127 {
                d.append(UInt8(b.count))
            } else {
                d.append(0x7F)
                var n = b.count - 127
                while n >= 128 { d.append(UInt8(n & 0x7F) | 0x80); n >>= 7 }
                d.append(UInt8(n))
            }
            d.append(contentsOf: b)
            return d
        }
        var d = Data([0x00])
        d.append(str(name)); d.append(str(value))
        return d
    }

    // MARK: - Protobuf

    /// QueryStatsResponse { repeated Stat stat = 1 }, Stat { string name = 1;
    /// int64 value = 2 }. Walks only the fields the response can contain.
    public static func parseProtobuf(_ data: Data) -> [XrayStat] {
        var stats: [XrayStat] = []
        var i = data.startIndex

        func varint(in d: Data, _ i: inout Data.Index) -> UInt64 {
            var v: UInt64 = 0, shift: UInt64 = 0
            while i < d.endIndex {
                let b = d[i]; i = d.index(after: i)
                v |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { break }
                shift += 7
            }
            return v
        }
        func lengthDelimited(in d: Data, _ i: inout Data.Index) -> Data? {
            // Keep the length as UInt64 and bound it against the remaining
            // bytes BEFORE the Int conversion: `Int(UInt64.max)` — a corrupt
            // or hostile 10-byte varint, e.g. from anything answering on the
            // unauthenticated loopback stats port while xray is down —
            // traps ("not enough bits") and kills the whole app process.
            let raw = varint(in: d, &i)
            guard raw <= UInt64(d.endIndex - i) else { return nil }
            let len = Int(raw)
            guard i <= d.endIndex,
                  let upper = d.index(i, offsetBy: len, limitedBy: d.endIndex) else { return nil }
            let sub = d.subdata(in: i..<upper)
            i = upper
            return sub
        }

        while i < data.endIndex {
            let tag = varint(in: data, &i)
            switch tag {
            case 1 << 3 | 2:                                     // repeated Stat
                guard let sub = lengthDelimited(in: data, &i) else { return stats }
                var j = sub.startIndex
                var name = ""
                var value: Int64 = 0
                while j < sub.endIndex {
                    let t = varint(in: sub, &j)
                    switch t {
                    case 1 << 3 | 2:
                        guard let s = lengthDelimited(in: sub, &j),
                              let str = String(data: s, encoding: .utf8) else { return stats }
                        name = str
                    case 2 << 3 | 0:
                        value = Int64(bitPattern: varint(in: sub, &j))
                    default: return stats                        // unknown → stop, keep what we have
                    }
                }
                stats.append(XrayStat(name: name, value: value))
            default:
                return stats                                      // not a Stat field → done
            }
        }
        return stats
    }
}