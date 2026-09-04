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
        if !trimmed.contains("://"), let decoded = Base64.decodeToString(trimmed) {
            text = decoded
        } else {
            text = trimmed
        }

        var servers: [ProxyServer] = []
        var failures: [(String, ParseError)] = []

        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line.contains("://") else { continue }
            do {
                servers.append(try ShareLinkParser.parse(line))
            } catch let e as ParseError {
                failures.append((line, e))
            } catch {
                failures.append((line, .malformedURI(line)))
            }
        }

        return Result(servers: servers, failures: failures)
    }
}
