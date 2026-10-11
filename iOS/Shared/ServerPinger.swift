import Foundation
import LoaderCore

/// One server to measure, in a form both the app and the extension can use.
struct PingTarget: Codable, Hashable {
    enum Method: String, Codable {
        /// Full TLS handshake — TLS and Reality servers.
        case tls
        /// Plain TCP connect — servers without TLS.
        case tcp
        /// ICMP echo — UDP servers (AmneziaWG, WireGuard, Hysteria), which
        /// answer neither probe above.
        case icmp
    }

    var id: UUID
    var host: String
    var port: Int
    var sni: String?
    var method: Method

    init(server: ProxyServer) {
        id = server.id
        host = server.address
        port = server.port
        // The name the engine itself presents: CDN and Reality entries often
        // carry an IP or a fronting host as the address.
        sni = server.sni ?? server.host
        if server.proto.isWireGuardFamily || server.proto.isHysteriaFamily {
            method = .icmp
        } else {
            method = server.security == .none ? .tcp : .tls
        }
    }
}

/// Round-trip times of one target, in ms; nil marks a lost attempt.
struct PingSample: Codable {
    var id: UUID
    var rtts: [Int?]
}

enum ServerPinger {
    /// `count` attempts per target, a few targets at a time: all at once would
    /// congest the uplink and skew the very numbers being measured.
    static func run(_ targets: [PingTarget], count: Int = 3, concurrency: Int = 6) async -> [PingSample] {
        await withTaskGroup(of: PingSample.self) { group in
            var pending = targets.makeIterator()
            var results: [PingSample] = []
            func enqueueNext() {
                guard let target = pending.next() else { return }
                group.addTask { await sample(target, count: count) }
            }
            for _ in 0..<concurrency { enqueueNext() }
            while let result = await group.next() {
                results.append(result)
                enqueueNext()
            }
            return results
        }
    }

    static func sample(_ target: PingTarget, count: Int) async -> PingSample {
        switch target.method {
        case .tls, .tcp:
            // Two misses in a row end it: a dead server shouldn't cost
            // count × timeout.
            let rtts = await LatencyProbe.sample(
                host: target.host, port: target.port, sni: target.sni, count: count, timeout: 3,
                tls: target.method == .tls, earlyAbortAfterFails: 2
            )
            return PingSample(id: target.id, rtts: rtts)
        case .icmp:
            let host = target.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            // getaddrinfo blocks. Here it would run on the cooperative pool,
            // where six of these already fill a phone's threads: a resolver
            // that black-holes queries then parks the extension, and the app
            // stops getting answers to anything else it asks.
            let address: String? = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: DirectResolver.isIPv4(host) ? host : DirectResolver.ipv4(host).first)
                }
            }
            guard let ip = address else {
                return PingSample(id: target.id, rtts: [nil])
            }
            var rtts: [Int?] = []
            var misses = 0
            for _ in 0..<count where misses < 2 {
                let rtt = await ICMPPing.echo(to: ip, timeout: 2)
                rtts.append(rtt)
                misses = rtt == nil ? misses + 1 : 0
            }
            return PingSample(id: target.id, rtts: rtts)
        }
    }
}

/// ICMP echo over a datagram socket, which iOS allows without privileges.
enum ICMPPing {
    static func echo(to ipv4: String, timeout: TimeInterval) async -> Int? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: echoBlocking(ipv4, timeout: timeout))
            }
        }
    }

    private static func echoBlocking(_ ipv4: String, timeout: TimeInterval) -> Int? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, ipv4, &address.sin_addr) == 1 else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let sequence = UInt16.random(in: 1...UInt16.max)
        var packet = [UInt8](repeating: 0, count: 24)
        packet[0] = 8 // echo request
        packet[4] = 0x41 // identifier (the kernel may replace it)
        packet[5] = 0x4E
        packet[6] = UInt8(sequence >> 8)
        packet[7] = UInt8(sequence & 0xFF)
        for index in 8..<packet.count { packet[index] = UInt8(index) }
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xFF)

        let start = DispatchTime.now().uptimeNanoseconds
        let sent = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else { return nil }

        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            let remaining = timeout - elapsed
            guard remaining > 0 else { return nil }
            var waiter = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&waiter, 1, Int32(remaining * 1000)) > 0 else { return nil }
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            // IPv4 datagram ICMP sockets deliver the IP header as well.
            let header = Int(buffer[0] & 0x0F) * 4
            guard count >= header + 8 else { continue }
            let replySequence = UInt16(buffer[header + 6]) << 8 | UInt16(buffer[header + 7])
            if buffer[header] == 0, replySequence == sequence {
                return Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
        }
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count { sum += UInt32(bytes[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }
}
