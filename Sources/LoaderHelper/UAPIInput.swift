import Foundation

/// The shape check the root helper runs on a UAPI script before writing it to
/// the engine.
///
/// What this can and cannot promise. It rejects non-printable bytes, CR-based
/// line confusion, an oversized payload and a document that doesn't open with
/// `set=1` — repeated here because the bytes are written here, and the app-side
/// sweep in `AmneziaWGConfigBuilder.makeUAPISetScript` is one call away over
/// XPC. It does NOT pretend to catch a smuggled newline: the script is
/// newline-delimited by design, so an injected line is syntactically
/// indistinguishable from a legitimate directive, and newline-free values are
/// the builder's job. The point is that the helper stops trusting its caller
/// for everything it can check locally.
enum UAPIInput {
    /// nil when the script may go through; otherwise why it may not.
    static func problem(_ script: String) -> String? {
        guard !script.isEmpty else { return "the config script is empty" }
        guard script.utf8.count <= 64 << 10 else {
            return "the config script is \(script.utf8.count) bytes, over the 65536 an AmneziaWG peer list needs"
        }
        guard script.hasSuffix("\n") else {
            return "the config script does not end with a newline — the engine's last line would be read unfinished"
        }
        guard script.hasPrefix("set=1\n") else {
            return "the config script does not open with `set=1`"
        }
        for character in script.unicodeScalars
        where character != "\n" && (character.value < 0x20 || character.value > 0x7E) {
            return "the config script carries U+\(String(character.value, radix: 16, uppercase: true)) "
                + "inside a line — only newline may separate directives"
        }
        return nil
    }
}
