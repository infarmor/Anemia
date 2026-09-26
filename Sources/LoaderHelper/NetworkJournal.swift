import Foundation
import LoaderShared

/// Root-owned locations the helper keeps state in. One directory, 0700, so an
/// unprivileged process can neither read the pf token nor swap a ruleset that
/// pfctl will load as root.
enum HelperPaths {
    static let stateDir = "/var/db/Loader"
}

/// Durable storage for ``NetworkJournal``: write-to-temp + fsync + rename +
/// directory fsync, so a power loss mid-write leaves either the old ledger or
/// the new one — never a torn file that decodes to nothing.
struct NetworkJournalStore: Sendable {
    enum StoreError: Error, CustomStringConvertible {
        case io(String, Int32)

        var description: String {
            switch self {
            case .io(let op, let code): return "\(op) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    let directory: String

    init(directory: String = HelperPaths.stateDir) {
        self.directory = directory
    }

    var path: String { directory + "/network-journal.json" }

    // Pre-0.8 helpers kept three separate files. They are folded into the
    // ledger on load and removed once the merged ledger is safely on disk.
    private var legacyDNSPath: String { directory + "/dns.backup.json" }
    private var legacyProxyPath: String { directory + "/proxy.backup.json" }
    private var legacyTokenPath: String { directory + "/killswitch.token" }

    var hasLegacyFiles: Bool {
        let fm = FileManager.default
        return [legacyDNSPath, legacyProxyPath, legacyTokenPath].contains { fm.fileExists(atPath: $0) }
    }

    /// The ledger plus anything a legacy helper left behind. A missing or
    /// unreadable file is an empty ledger.
    func load() -> NetworkJournal {
        var journal = NetworkJournal()
        if let data = FileManager.default.contents(atPath: path),
           let decoded = try? JSONDecoder().decode(NetworkJournal.self, from: data) {
            journal = decoded
        }
        mergeLegacy(into: &journal)
        return journal
    }

    func save(_ journal: NetworkJournal) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(journal)
        let tmp = path + ".tmp"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw StoreError.io("open journal", errno) }
        let written = data.withUnsafeBytes { raw -> Int in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { return -1 }
                offset += n
            }
            return offset
        }
        guard written == data.count else {
            let code = errno
            close(fd)
            unlink(tmp)
            throw StoreError.io("write journal", code)
        }
        guard fsync(fd) == 0 else {
            let code = errno
            close(fd)
            unlink(tmp)
            throw StoreError.io("fsync journal", code)
        }
        close(fd)
        guard rename(tmp, path) == 0 else {
            let code = errno
            unlink(tmp)
            throw StoreError.io("rename journal", code)
        }
        let dfd = open(directory, O_RDONLY)
        if dfd >= 0 {
            fsync(dfd)
            close(dfd)
        }
    }

    /// Remove the pre-0.8 files — only after their content is in a saved ledger.
    func removeLegacyFiles() {
        for p in [legacyDNSPath, legacyProxyPath, legacyTokenPath] {
            unlink(p)
        }
    }

    private func ensureDirectory() throws {
        var st = stat()
        if stat(directory, &st) == 0 {
            if st.st_mode & 0o077 != 0 { chmod(directory, 0o700) }
            return
        }
        guard mkdir(directory, 0o700) == 0 || errno == EEXIST else {
            throw StoreError.io("mkdir \(directory)", errno)
        }
    }

    private func mergeLegacy(into journal: inout NetworkJournal) {
        if let data = FileManager.default.contents(atPath: legacyDNSPath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] {
            for (service, servers) in obj.sorted(by: { $0.key < $1.key })
            where !journal.dns.contains(where: { $0.service == service }) {
                journal.dns.append(.init(service: service,
                                         prior: NetworkSettingsPolicy.sanitizePriorDNS(servers, liveIPv4: []),
                                         applied: []))
            }
        }
        if let data = FileManager.default.contents(atPath: legacyProxyPath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] {
            for (service, parts) in obj.sorted(by: { $0.key < $1.key })
            where parts.count == 3 && !journal.proxy.contains(where: { $0.service == service }) {
                var prior = ProxySetting(enabled: parts[0] == "1", host: parts[1], port: Int(parts[2]) ?? 0)
                // A legacy backup could hold a leftover engine pin as "prior".
                if NetworkSettingsPolicy.isLoopbackHost(prior.host) { prior = .off }
                journal.proxy.append(.init(service: service, prior: prior,
                                           applied: ProxySetting(enabled: true, host: "127.0.0.1", port: 0)))
            }
        }
        if let raw = try? String(contentsOfFile: legacyTokenPath, encoding: .utf8) {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if journal.pfToken == nil, token.allSatisfy(\.isNumber), !token.isEmpty {
                journal.pfToken = token
            }
            journal.legacyMainRuleset = true
        }
    }
}
