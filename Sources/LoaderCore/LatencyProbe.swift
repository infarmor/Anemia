import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Measures TCP connect latency to a server endpoint — the standard proxy
/// "ping" — without needing the engine running. Used to rank imported servers
/// and auto-connect to the fastest one.
public enum LatencyProbe {

    /// One TCP handshake RTT in milliseconds, or nil on timeout/refused/failure.
    public static func tcpPing(host: String, port: Int, timeout: TimeInterval = 3) async -> Int? {
        await Task.detached(priority: .userInitiated) {
            blockingTCPPing(host: host, port: port, timeoutMs: Int(timeout * 1000))
        }.value
    }

    /// Ping `count` times and return per-attempt results (nil = failed attempt),
    /// spaced slightly apart, for jitter/loss statistics.
    public static func sample(host: String, port: Int, count: Int = 3, timeout: TimeInterval = 3) async -> [Int?] {
        var results: [Int?] = []
        for _ in 0..<max(1, count) {
            results.append(await tcpPing(host: host, port: port, timeout: timeout))
        }
        return results
    }

    // MARK: - Blocking implementation (pure, runs off the main actor)

    private static func blockingTCPPing(host: String, port: Int, timeoutMs: Int) -> Int? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else { return nil }
        defer { freeaddrinfo(res) }

        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let start = DispatchTime.now()
        let cres = connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
        if cres == 0 { return elapsedMs(start) }
        guard errno == EINPROGRESS else { return nil }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pr = poll(&pfd, 1, Int32(timeoutMs))
        guard pr > 0 else { return nil }   // 0 = timeout, <0 = error

        var soErr: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
        return soErr == 0 ? elapsedMs(start) : nil
    }

    private static func elapsedMs(_ start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }
}
