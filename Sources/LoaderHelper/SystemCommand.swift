import Foundation

/// Runs system tools (`ifconfig`, `route`, `tun2socks`) as root. The helper is
/// the only component allowed to do this.
enum SystemCommand {
    struct Result {
        let status: Int32
        let output: String
        var ok: Bool { status == 0 }
    }

    /// Run a command to completion and capture combined stdout/stderr.
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            return Result(status: -1, output: "spawn failed: \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return Result(status: proc.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Networking primitives

    /// Resolve a host to addresses of the given family (AF_INET / AF_INET6).
    static func resolve(_ host: String, family: Int32) -> [String] {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG, ai_family: family, ai_socktype: SOCK_STREAM,
            ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
        )
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0 else { return [] }
        defer { freeaddrinfo(res) }

        var ips: [String] = []
        var node = res
        while let cur = node {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(cur.pointee.ai_addr, cur.pointee.ai_addrlen,
                           &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: buf)
                if !ips.contains(ip) { ips.append(ip) }
            }
            node = cur.pointee.ai_next
        }
        return ips
    }

    static func resolveIPv4(_ host: String) -> [String] { resolve(host, family: AF_INET) }
    static func resolveIPv6(_ host: String) -> [String] { resolve(host, family: AF_INET6) }

    /// The current default gateway for the given family (`-inet` / `-inet6`).
    static func defaultGateway(inet6: Bool = false) -> String? {
        let r = run("/sbin/route", ["-n", "get", inet6 ? "-inet6" : "-inet", "default"])
        guard r.ok else { return nil }
        for line in r.output.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("gateway:") {
                return t.replacingOccurrences(of: "gateway:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Whether a network interface currently exists.
    static func interfaceExists(_ name: String) -> Bool {
        run("/sbin/ifconfig", [name]).ok
    }

    /// Pick a utun name that isn't currently in use.
    static func freeUtunName() -> String {
        for n in 90...120 where !interfaceExists("utun\(n)") {
            return "utun\(n)"
        }
        return "utun99"
    }
}
