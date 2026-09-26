import Foundation

/// Is the VPN really carrying everything? The address the internet sees,
/// the resolvers that answer this device's lookups, and — measured from
/// outside the tunnel — the address the provider gave, compared.
public enum LeakCheck {
    public struct IPInfo: Codable, Equatable, Sendable {
        public var ip: String
        /// ISO region code, upper case.
        public var countryCode: String?
        public var country: String?
        public var city: String?
        /// The provider (or hoster) behind the address.
        public var isp: String?

        public init(ip: String, countryCode: String? = nil, country: String? = nil,
                    city: String? = nil, isp: String? = nil) {
            self.ip = ip
            self.countryCode = countryCode
            self.country = country
            self.city = city
            self.isp = isp
        }
    }

    public struct DNSServer: Codable, Equatable, Sendable {
        public var ip: String
        public var countryCode: String?
        public var country: String?
        public var org: String?

        public init(ip: String, countryCode: String? = nil, country: String? = nil, org: String? = nil) {
            self.ip = ip
            self.countryCode = countryCode
            self.country = country
            self.org = org
        }
    }

    public enum Finding: Equatable, Sendable {
        /// The internet sees the provider's address: traffic isn't in the tunnel.
        case tunnelBypassed
        /// IPv6 goes out from the home country.
        case ipv6Leak(IPInfo)
        /// These resolvers sit in the home country: the provider can see the
        /// names being looked up.
        case dnsLeak([DNSServer])
    }

    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    // MARK: - Measuring

    /// The address the internet sees for this process's traffic. IPv6 fails
    /// (throws) when there is no IPv6 route at all.
    public static func publicAddress(ipv6: Bool = false, session: URLSession = .shared) async throws -> IPInfo {
        let host = ipv6 ? "https://api-ipv6.ip.sb/geoip" : "https://api-ipv4.ip.sb/geoip"
        do {
            return try await ipSB(URL(string: host)!, session: session)
        } catch where !ipv6 {
            // Cloudflare knows the country, not the provider.
            return try await cloudflareTrace(session: session)
        }
    }

    /// The resolvers behind this process's lookups: bash.ws hands out a
    /// fresh name, sees who asks its authoritative server about it, and
    /// reports them. `resolve` looks a name up the way the device would.
    public static func dnsServers(session: URLSession = .shared,
                                  resolve: @escaping @Sendable (String) async -> Void) async throws -> [DNSServer] {
        // A request without a timeout waits out URLSession's 60 seconds; two
        // of them in a row is a leak-check screen stuck on "Проверяю DNS…"
        // for a couple of minutes with no way to stop it.
        var idRequest = URLRequest(url: URL(string: "https://bash.ws/id")!,
                                   cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        let (idData, _) = try await session.data(for: idRequest)
        let id = String(decoding: idData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            throw Failure(message: "bash.ws: unexpected id")
        }
        await withTaskGroup(of: Void.self) { group in
            for index in 1...6 {
                group.addTask { await resolve("\(index).\(id).bash.ws") }
            }
        }
        let resultRequest = URLRequest(url: URL(string: "https://bash.ws/dnsleak/test/\(id)?json")!,
                                       cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        let (data, _) = try await session.data(for: resultRequest)
        return try parseBashWS(data)
    }

    // MARK: - Judging

    /// What's wrong, comparing what the tunnel shows (`exit`) with the
    /// provider's own address (`direct`, measured outside the tunnel).
    /// Empty: nothing leaks — or there's no direct address to compare with.
    public static func findings(exit: IPInfo?, direct: IPInfo?, ipv6: IPInfo?, dns: [DNSServer]) -> [Finding] {
        guard let direct else { return [] }
        var findings: [Finding] = []
        if let exit, exit.ip == direct.ip {
            findings.append(.tunnelBypassed)
        }
        let home = direct.countryCode?.uppercased()
        let away = exit?.countryCode?.uppercased()
        // A home-country exit hides nothing by country: say only what's certain.
        guard let home, home != away else { return findings }
        if let ipv6, ipv6.countryCode?.uppercased() == home {
            findings.append(.ipv6Leak(ipv6))
        }
        let local = dns.filter { $0.countryCode?.uppercased() == home }
        if !local.isEmpty {
            findings.append(.dnsLeak(local))
        }
        return findings
    }

    // MARK: - Parsing

    static func ipSB(_ url: URL, session: URLSession) async throws -> IPInfo {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("Anemia", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        return try parseIPSB(data)
    }

    public static func parseIPSB(_ data: Data) throws -> IPInfo {
        struct Raw: Decodable {
            var ip: String
            var country_code: String?
            var country: String?
            var city: String?
            var isp: String?
            var asn_organization: String?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data), !raw.ip.isEmpty else {
            throw Failure(message: "ip.sb: unexpected answer")
        }
        return IPInfo(ip: raw.ip, countryCode: raw.country_code?.uppercased(), country: raw.country,
                      city: raw.city, isp: raw.isp ?? raw.asn_organization)
    }

    static func cloudflareTrace(session: URLSession) async throws -> IPInfo {
        let request = URLRequest(url: URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        let (data, _) = try await session.data(for: request)
        return try parseTrace(data)
    }

    public static func parseTrace(_ data: Data) throws -> IPInfo {
        var fields: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        guard let ip = fields["ip"], !ip.isEmpty else { throw Failure(message: "Cloudflare: unexpected answer") }
        return IPInfo(ip: ip, countryCode: fields["loc"]?.uppercased())
    }

    public static func parseBashWS(_ data: Data) throws -> [DNSServer] {
        struct Raw: Decodable {
            var ip: String
            var country: String?
            var country_name: String?
            var asn: String?
            var org: String?
            var type: String
        }
        guard let entries = try? JSONDecoder().decode([Raw].self, from: data) else {
            throw Failure(message: "bash.ws: unexpected answer")
        }
        var seen = Set<String>()
        return entries.compactMap { entry in
            guard entry.type == "dns", seen.insert(entry.ip).inserted else { return nil }
            return DNSServer(ip: entry.ip, countryCode: entry.country?.uppercased(), country: entry.country_name,
                             org: entry.org ?? entry.asn)
        }
    }
}
