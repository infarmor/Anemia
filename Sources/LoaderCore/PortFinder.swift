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

    /// The preferred port if it's free, otherwise an OS-assigned free port,
    /// avoiding any in `exclude`.
    public static func pick(preferred: Int, exclude: Set<Int> = []) -> Int {
        if !exclude.contains(preferred), isFree(preferred) { return preferred }
        for _ in 0..<20 {
            if let p = freePort(), !exclude.contains(p) { return p }
        }
        return preferred
    }
}
