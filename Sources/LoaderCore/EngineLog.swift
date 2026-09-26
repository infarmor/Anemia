import Foundation

/// Reading the engine's own output.
public enum EngineLog {
    /// The one line worth showing when xray dies during startup.
    ///
    /// xray reports a startup failure as a single "Failed to start: …" line
    /// whose cause is a ` > `-separated chain, from the outermost wrapper
    /// ("main: failed to load config files: [/var/…/loader-xray-….json]")
    /// down to the root cause ("listen tcp 127.0.0.1:10808: bind: address
    /// already in use"). Only the innermost link says what to fix, so that is
    /// what surfaces, minus a Go package prefix ("infra/conf: "). Output
    /// without such a line falls back to the last failure-looking line, then
    /// the last line at all.
    public static func failureReason(from lines: [String]) -> String {
        if let line = lines.last(where: { $0.contains("Failed to start") }) {
            let chain = line.components(separatedBy: " > ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard chain.count > 1, let cause = chain.last else { return line }
            return stripPackagePrefix(cause)
        }
        if let line = lines.last(where: {
            $0.localizedCaseInsensitiveContains("failed") || $0.localizedCaseInsensitiveContains("invalid")
        }) {
            return line
        }
        return lines.last ?? "engine exited during startup"
    }

    /// "infra/conf: Failed to build TLS config." → "Failed to build TLS config."
    /// Only a slash-separated, space-free token counts as a package path, so a
    /// Go error like "listen tcp 127.0.0.1:1080: bind: …" is left intact.
    static func stripPackagePrefix(_ s: String) -> String {
        guard let colon = s.range(of: ": ") else { return s }
        let head = s[..<colon.lowerBound]
        guard head.contains("/"), !head.contains(" ") else { return s }
        let rest = s[colon.upperBound...]
        return rest.isEmpty ? s : String(rest)
    }
}
