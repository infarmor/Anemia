import Foundation

/// Base64 decoding that tolerates the sloppy variants seen in proxy share
/// links and subscriptions: URL-safe alphabet (`-_`) and missing `=` padding.
public enum Base64 {

    /// Decode standard or URL-safe base64, with or without padding.
    public static func decodeFlexible(_ input: String) -> Data? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // Normalize URL-safe alphabet to standard.
        s = s.replacingOccurrences(of: "-", with: "+")
             .replacingOccurrences(of: "_", with: "/")

        // Restore padding to a multiple of 4.
        let remainder = s.count % 4
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
