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
            return cause(from: line)
        }
        if let line = lines.last(where: looksLikeFailure) {
            return line
        }
        return lines.last ?? "engine exited during startup"
    }

    /// The innermost cause of one engine error text, chain or not.
    ///
    /// This is what the Android port needs rather than [failureReason(from:)]:
    /// there the engine lives in the process, so the startup failure arrives as
    /// the *returned error string* (`xray config: … > …`) and never as a log
    /// line with xray's command-line "Failed to start: " wrapper. The chain is
    /// the same text on both platforms — only its envelope differs — so the
    /// rule is shared and neither side invents its own.
    ///
    /// A text without a ` > `-chain comes back trimmed and otherwise untouched:
    /// "Failed to start: boom" is all there is, and dropping the wrapper would
    /// leave the user with a word and no context.
    public static func cause(from text: String) -> String {
        let chain = text.components(separatedBy: " > ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard chain.count > 1, let cause = chain.last else {
            return text.trimmingCharacters(in: .whitespaces)
        }
        return stripPackagePrefix(cause)
    }

    /// "infra/conf: Failed to build TLS config." → "Failed to build TLS config."
    /// Only a slash-separated, space-free token counts as a package path, so a
    /// Go error like "listen tcp 127.0.0.1:1080: bind: …" is left intact.
    static func stripPackagePrefix(_ s: String) -> String {
        guard let colon = s.range(of: ": ") else { return s }
        let head = s[..<colon.lowerBound]
        guard head.contains("/"), !head.contains(" ") else { return s }
        // Пустой хвост здесь невозможен: звено цепочки уже обрезано, и «: » на
        // конце не выживает. Когда-то эта ветка была — и ни один мутант её не
        // трогал, то есть она только притворялась защитой.
        return String(s[colon.upperBound...])
    }

    /// Whether a log line reads as a failure. ASCII-only folding, deliberately:
    /// Foundation's `localizedCaseInsensitiveContains` consults the user's
    /// locale, and in a Turkish locale "FAILED" stops matching "failed" (dotted
    /// capital I), which would make the fallback line depend on the language
    /// setting of the device. The engine writes these words in ASCII English;
    /// the rest of the line may carry user text, and that must not matter.
    public static func looksLikeFailure(_ line: String) -> Bool {
        var lowered = String.UnicodeScalarView()
        for scalar in line.unicodeScalars {
            // A-Z → a-z; всё остальное — как есть, без языковых сюрпризов.
            if scalar.value >= 65, scalar.value <= 90 {
                lowered.append(UnicodeScalar(scalar.value + 32)!)
            } else {
                lowered.append(scalar)
            }
        }
        let text = String(lowered)
        return text.contains("failed") || text.contains("invalid")
    }
}
