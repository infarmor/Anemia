import Foundation

/// Which masking records can actually be handed to the engine.
///
/// Junk packets moved. 26.3.27 reads them from the masking `freedom`
/// outbound's `settings.noises`, not from a socket option (measured on the
/// shipped binary: a bad `sockopt.interface` fails the decode while
/// `sockopt.noises`, garbage included, is silently ignored — so emitting them
/// there gave every profile except `off` a knob that did nothing). The key is
/// live now, and it is read STRICTLY: `FreedomConfig.Build` rejects a record
/// it dislikes and takes the whole config down with it. Same for
/// `settings.fragment`. That makes the shape a failure mode rather than a
/// cosmetic one — one record a panel wrote or an old state file kept, and the
/// tunnel stops starting for a knob nobody would miss.
///
/// So the rule is not "is this a sensible noise" but "will `xray run` load
/// it", and the answer is taken from the pinned engine's own source
/// (`infra/conf/freedom.go`, `infra/conf/common.go`):
///
///  * `type` matches `rand` / `str` / `hex` / `base64` CASE-SENSITIVELY —
///    `Rand` is `Invalid packet, only rand/str/hex/base64 are supported`.
///  * `packet` is `strings.TrimSpace`'d first, which is why `" 50"` is a valid
///    length but `"10 - 16"` is not (the inner space survives).
///  * `delay` is NOT trimmed, and is parsed as an `Int32Range`; a value the
///    engine cannot parse is a config error, while `""` and a missing key are
///    both fine.
///  * Anything the engine accepts we pass through unedited, including the
///    records that look useless (`str` with an empty payload) and the ranges
///    that look backwards (`100-50`, which the engine keeps for `rand` and
///    merely reorders for a delay). Filtering more than the engine would
///    silently drop part of a user's profile; filtering less takes the tunnel
///    down. Both are worse than the bug this replaces.
public extension AntiCensorshipOptions {
    /// The noises to emit, in the order the profile lists them, minus any the
    /// engine would refuse to load.
    var emittableNoises: [Noise] { noises.filter(\.isEmittable) }

    /// The fragment to emit, or `nil` when the engine would refuse to load it.
    var emittableFragment: Fragment? { fragment.flatMap { $0.isEmittable ? $0 : nil } }
}

public extension AntiCensorshipOptions.Noise {
    var isEmittable: Bool {
        guard XrayRange.parse(delay) != nil else { return false }
        let payload = packet.trimmingCharacters(in: XrayRange.engineWhitespace)
        switch type {
        case "rand":
            // `rand lengthMin or lengthMax cannot be 0` — the check is on the
            // LEFT value as written, so "100-50" survives and "-5" survives
            // (it becomes a huge uint64), while "0-100" and "" do not.
            guard let (lo, _) = XrayRange.parse(payload) else { return false }
            return lo != 0
        case "str":
            return true
        case "hex":
            // `hex.DecodeString`: an even number of BYTES of hex digits.
            let bytes = Array(payload.utf8)
            return bytes.count % 2 == 0 && bytes.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102)
            }
        case "base64":
            // `base64.RawURLEncoding.DecodeString` of the packet with `+` →
            // `-`, `/` → `_` and every `=` deleted. Raw means unpadded, so a
            // length that leaves a single trailing character is the one
            // corruption it reports — `Data(base64Encoded:)` disagrees (it
            // refuses unpadded input), hence the hand-rolled check.
            var bytes: [UInt8] = []
            for byte in payload.utf8 {
                switch byte {
                case UInt8(ascii: "+"): bytes.append(UInt8(ascii: "-"))
                case UInt8(ascii: "/"): bytes.append(UInt8(ascii: "_"))
                case UInt8(ascii: "="): break
                default: bytes.append(byte)
                }
            }
            guard bytes.count % 4 != 1 else { return false }
            return bytes.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                    || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "_")
            }
        default:
            return false
        }
    }
}

public extension AntiCensorshipOptions.Fragment {
    var isEmittable: Bool {
        // `packets` is lower-cased only for the `tlshello` test; the range
        // branch then reads the ORIGINAL string, untrimmed.
        switch packets.lowercased() {
        case "", "tlshello":
            break
        default:
            guard let (lo, _) = XrayRange.parse(packets), lo != 0 else { return false }
        }
        // `length` and `interval` are `*Int32Range`: absent or unparseable is
        // `Length can't be empty`. A parsed range is reordered (`From < To`)
        // before the zero check, so "100-0" is as fatal as "0-100" here even
        // though `rand` keeps the left value as written.
        guard let (lo, hi) = XrayRange.parse(length), min(lo, hi) != 0 else { return false }
        guard XrayRange.parse(interval) != nil else { return false }
        return true
    }
}

/// `ParseRangeString` from `infra/conf/common.go` of the pinned engine, plus
/// the whitespace set its callers trim. Shared by the Swift emitter and the
/// Kotlin mirror, so the two platforms agree on which profiles mask and which
/// do not.
enum XrayRange {
    /// `strings.TrimSpace` trims Unicode spaces, which Kotlin's `trim()` does
    /// not know about and Go's does. The ASCII members of that set are the
    /// ones a panel can plausibly emit, and trimming only those keeps us a
    /// SUBSET of the engine: we may drop a record Go would have salvaged, but
    /// never hand it one it will reject.
    static let engineWhitespace = CharacterSet(charactersIn: " \t\n\u{000B}\u{000C}\r")

    /// A plain integer Go's `strconv.Atoi` accepts (`+10` and `-0` are
    /// numbers, ` 10`, `1_0` and `99999999999999999999` are not), `""` which
    /// the engine reads as zero, or `lo-hi` — where a leading `-` belongs to
    /// the low bound and the split happens at the SECOND dash, so `-114-514`
    /// is (-114, 514) while `-5` is a plain number and `--1` is nothing.
    static func parse(_ text: String) -> (Int, Int)? {
        if let single = Int64(text) { return (Int(single), Int(single)) }
        if text.isEmpty { return (0, 0) }
        let pair: [String]
        if text.hasPrefix("-") {
            let head = text.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
            guard head.count == 3 else { return nil }
            pair = [String(head[0]) + "-" + String(head[1]), String(head[2])]
        } else {
            pair = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        }
        guard pair.count == 2, let lo = Int64(pair[0]), let hi = Int64(pair[1]) else { return nil }
        return (Int(lo), Int(hi))
    }
}
