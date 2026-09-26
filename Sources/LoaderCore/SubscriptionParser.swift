import Foundation

/// Parses subscription payloads into a list of ``ProxyServer``.
///
/// The common v2ray/xray subscription format is a base64 blob whose decoded
/// text is one share link per line. Some panels serve the links as plain text
/// (already decoded). This handles both, and skips lines it can't parse rather
/// than failing the whole import.
public enum SubscriptionParser {

    public struct Result: Sendable {
        public var servers: [ProxyServer]
        /// Links that failed to parse, kept for diagnostics/UI.
        public var failures: [(line: String, error: ParseError)]

        public init(servers: [ProxyServer], failures: [(line: String, error: ParseError)]) {
            self.servers = servers
            self.failures = failures
        }
    }

    /// Parse a raw subscription body (as fetched from a subscription URL, or
    /// pasted by the user).
    public static func parse(_ body: String) -> Result {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Result(servers: [], failures: []) }

        // If the body looks like a single base64 blob (no scheme markers and no
        // newlines), decode it first.
        let text: String
        var undecodable = false
        if !trimmed.contains("://"), let decoded = Base64.decodeToString(trimmed) {
            text = decoded
        } else if !trimmed.contains("://") {
            // A blob that decodes to nothing is garbage, not an empty
            // subscription: returning all-empty used to make the refresh
            // path WIPE the subscription's saved server list, silently, and
            // auto-refresh would repeat that every 6 h. Surface a failure
            // instead so the caller can keep the old servers.
            text = trimmed
            undecodable = true
        } else {
            text = trimmed
        }

        var servers: [ProxyServer] = []
        var failures: [(String, ParseError)] = []

        // One entry per distinct server: panels hand out the same link on
        // several lines (and subscription re-publishes repeat them), which
        // showed as duplicate rows, doubled every probe and grew the state file
        // on each refresh. identityKey is the same "is this the same server"
        // test that carryingIDs already uses.
        var seen: Set<String> = []
        // `isNewline`, not `== "\n" || == "\r"`: a CRLF is one grapheme cluster,
        // so comparing it to either half never matches and a body with Windows
        // line endings collapsed into a single "link" — one server with the rest
        // of the subscription glued onto its name, and every panel link after
        // the first silently dropped.
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line.contains("://") else { continue }
            do {
                let server = try ShareLinkParser.parse(line)
                if seen.insert(server.identityKey).inserted { servers.append(server) }
            } catch let e as ParseError {
                failures.append((line, e))
            } catch {
                failures.append((line, .malformedURI(line)))
            }
        }

        if undecodable, servers.isEmpty, failures.isEmpty {
            failures.append((String(trimmed.prefix(80)), .malformedURI(
                "subscription body is not decodable base64 and contains no share links")))
        }

        return Result(servers: servers, failures: failures)
    }

    /// Carry server IDs across a refresh: a server whose identity (link text)
    /// was already listed keeps that entry's ID, so the selection survives an
    /// update and ping history doesn't orphan. Each old ID is handed out at
    /// most once — a subscription listing the same link twice used to give
    /// both copies one ID, and duplicate IDs break every id-keyed list,
    /// selection and lookup. Extra copies keep their fresh IDs.
    public static func carryingIDs(from old: [ProxyServer], into fresh: [ProxyServer]) -> [ProxyServer] {
        var pool: [String: [UUID]] = [:]
        for server in old { pool[server.identityKey, default: []].append(server.id) }
        var used = Set<UUID>()
        return fresh.map { server in
            var carried = server
            while var ids = pool[carried.identityKey], !ids.isEmpty {
                let id = ids.removeFirst()
                pool[carried.identityKey] = ids
                if used.insert(id).inserted {
                    carried.id = id
                    break
                }
            }
            return carried
        }
    }
}
