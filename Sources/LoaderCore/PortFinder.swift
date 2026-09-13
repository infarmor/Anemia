import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Finds free local TCP ports so the engine's inbounds never fail to bind when
/// the default ports are already taken (another instance, another app, a
/// lingering process). Improves connection reliability.
public enum PortFinder {

    /// Ask the OS for a free ephemeral port by binding 127.0.0.1:0.
    public static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    /// Whether a specific TCP port on 127.0.0.1 is currently bindable.
    public static func isFree(_ port: Int) -> Bool {
        guard port > 0, port < 65536 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        let res = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return res == 0
    }

    /// Whether something on 127.0.0.1:`port` currently accepts TCP connections.
    /// Complements `isFree` (bind probe) — this is the engine-liveness probe
    /// used after spawning xray to confirm its inbound actually opened.
    public static func canConnect(_ port: Int, timeoutMs: Int = 200) -> Bool {
        guard port > 0, port < 65536 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        // Non-blocking connect so a firewalled/half-open port can't stall the
        // caller; POLLOUT + SO_ERROR is the standard completion check.
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        let res = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if res == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let polled = poll(&pfd, 1, Int32(timeoutMs))
        guard polled > 0, pfd.revents & Int16(POLLOUT) != 0 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }

    /// The preferred port if it's free, otherwise an OS-assigned free port,
    /// avoiding any in `exclude`.
    ///
    /// The last-resort fallback returns the busy `preferred` anyway: callers
    /// pin it into the config and probe it (`waitForPort`), so a colliding
    /// start still fails with a clear "did not open SOCKS port" reason —
    /// whereas a made-up port number here would silently disagree with the
    /// one the config actually carries.
    public static func pick(preferred: Int, exclude: Set<Int> = []) -> Int {
        if !exclude.contains(preferred), isFree(preferred) { return preferred }
        for _ in 0..<20 {
            if let p = freePort(), !exclude.contains(p) { return p }
        }
        return preferred
    }
}
