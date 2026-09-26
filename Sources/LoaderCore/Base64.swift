import Foundation

/// Base64 decoding that tolerates the sloppy variants seen in proxy share
/// links and subscriptions: URL-safe alphabet (`-_`) and missing `=` padding.
public enum Base64 {

    /// Decode standard or URL-safe base64, with or without padding.
    public static func decodeFlexible(_ input: String) -> Data? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // Normalize URL-safe alphabet to standard. Gate the rewrite on an
        // actual URL-safe character: the two replacingOccurrences used to
        // scan + copy the whole string twice per call on the common
        // (standard-alphabet) path — a subscription import pays this for
        // every line it decodes.
        if s.contains(where: { $0 == "-" || $0 == "_" }) {
            s = s.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        }

        // Restore padding to a multiple of 4 — computed on the ALPHABET-ONLY
        // view, not the raw string. `%4` used to count characters that
        // `.ignoreUnknownCharacters` drops, so one stray interior character
        // (a BOM, zero-width space, `%`) corrupted the padding and broke a
        // decode that would otherwise succeed. The string itself is left
        // untouched: newlines are STRUCTURAL in multi-line subscription
        // blobs (dropping them glues every link together), and the decoder's
        // ignore-unknown pass removes anything non-alphabet anyway.
        let alphabetOnly = s.filter {
            ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_"
                || $0 == "+" || $0 == "/" || $0 == "="
        }
        let remainder = alphabetOnly.count % 4
        if remainder > 0 {
            s.append(String(repeating: "=", count: 4 - remainder))
        }

        return Data(base64Encoded: s, options: [.ignoreUnknownCharacters])
    }

    /// Decode flexible base64 to a UTF-8 string, if valid.
    public static func decodeToString(_ input: String) -> String? {
        decodeFlexible(input).flatMap { String(data: $0, encoding: .utf8) }
    }
}
