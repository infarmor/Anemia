import Foundation
import Testing
@testable import LoaderCore

/// Junk packets and ClientHello fragmentation are read STRICTLY from
/// `settings.noises` / `settings.fragment` on the masking `freedom` outbound,
/// so a record the engine dislikes is not a cosmetic problem — it is a config
/// that will not start, for a profile the user did not change.
///
/// Every ACCEPT/REJECT in the tables below is a measured verdict from
/// `Resources/xray` (26.3.27, `xray run -test`) with that single record in an
/// otherwise valid config, not a reading of the docs. The grammar is
/// `ParseNoise` + `ParseRangeString` in `infra/conf/` of the pinned engine.
struct MaskingGrammarTests {
    private func noise(_ type: String, _ packet: String, _ delay: String) -> AntiCensorshipOptions.Noise {
        AntiCensorshipOptions.Noise(type: type, packet: packet, delay: delay)
    }

    /// One row of the shared grammar fixture — the same file the Kotlin parity
    /// check reads and `Scripts/verify-noise-grammar.sh` re-measures against
    /// the binary. A missing or short fixture is a failure, never a skip: an
    /// empty table would "pass" every row in it.
    private static func grammarRows() throws -> [(kind: String, a: String, b: String, c: String, accept: Bool)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Android/core/src/test/resources/mask/grammar.tsv")
        let text = try String(contentsOf: url, encoding: .utf8)
        var rows: [(kind: String, a: String, b: String, c: String, accept: Bool)] = []
        for line in text.split(whereSeparator: \ .isNewline) {
            if line.hasPrefix("#") || line.allSatisfy(\.isWhitespace) { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5 else {
                Issue.record("строка из \(fields.count) полей, ждалось 5: \(line)")
                continue
            }
            guard let verdict = ["accept": true, "reject": false][fields[4]] else {
                Issue.record("не вердикт в последней колонке: \(fields[4])")
                continue
            }
            // `%20` is a literal space in the fixture: a TSV reader that trims
            // would eat the whitespace rows this table exists to prove.
            func decode(_ value: String) -> String { value.replacingOccurrences(of: "%20", with: " ") }
            rows.append((fields[0], decode(fields[1]), decode(fields[2]), decode(fields[3]), verdict))
        }
        return rows
    }

    @Test func grammarTableMatchesTheFilter() throws {
        let rows = try Self.grammarRows()
        #expect(rows.count == 99, "строк в эталоне: \(rows.count), ждалось 99")
        #expect(rows.filter(\.accept).count == 54, "accept-строк: \(rows.filter(\.accept).count)")
        #expect(rows.filter { !$0.accept }.count == 45, "reject-строк: \(rows.filter { !$0.accept }.count)")
        for row in rows {
            let emittable: Bool
            switch row.kind {
            case "noise":
                emittable = AntiCensorshipOptions.Noise(type: row.a, packet: row.b, delay: row.c).isEmittable
            case "frag":
                emittable = AntiCensorshipOptions.Fragment(packets: row.a, length: row.b, interval: row.c).isEmittable
            default:
                Issue.record("неизвестный kind \(row.kind)")
                continue
            }
            let verdict = row.accept ? "принял" : "отбраковал"
            #expect(emittable == row.accept,
                    "движок \(verdict), фильтр — \(emittable): [\(row.kind)] [\(row.a)] [\(row.b)] [\(row.c)]")
        }
    }

    /// The engine's `TrimSpace` also covers U+00A0, which Kotlin's `trim()` and
    /// our shared ASCII set do not. Measured verdict was ACCEPT, and we drop it
    /// — deliberately the SUBSET direction: salvaging less than the engine
    /// wastes one junk packet, pretending to salvage more would hand the
    /// engine a record it rejects and take the tunnel down.
    @Test func exoticWhitespaceIsDroppedNotEmitted() throws {
        #expect(!noise("hex", "\u{00A0}0a", "10").isEmittable)
        #expect(AntiCensorshipOptions(noises: [noise("hex", "\u{00A0}0a", "10")]).emittableNoises.isEmpty)
    }

    @Test func filterKeepsProfileOrderAndDropsOnlyBadRecords() throws {
        let options = AntiCensorshipOptions(noises: [
            noise("rand", "50-100", "10-16"),
            noise("hex", "zz", "10"),
            noise("str", "hello", "10"),
            noise("Rand", "50-100", "10"),
        ])
        #expect(options.emittableNoises.map(\.type) == ["rand", "str"],
                "filtering must not reorder or over-drop")
        #expect(AntiCensorshipOptions(noises: []).emittableNoises.isEmpty)
    }

    @Test func recommendedPresetsSurviveTheFilter() throws {
        // Every built-in profile is written by us, so the filter must be
        // invisible for all of them — a preset that silently lost its junk is
        // the same bug in the other direction.
        for preset in [AntiCensorshipOptions.balanced, .recommended, .maximum,
                       .russiaYandex, .russiaVK] {
            #expect(preset.emittableNoises.count == preset.noises.count,
                    "\(preset.noises.count - preset.emittableNoises.count) noise(s) dropped from a built-in profile")
            if preset.fragment != nil {
                #expect(preset.emittableFragment != nil, "a built-in fragment was dropped")
            } else {
                #expect(preset.emittableFragment == nil)
            }
        }
    }
}

/// Where the masking keys live in the emitted config.
///
/// `sockopt.noises` was the historic home and it never existed: on 26.3.27 an
/// unknown socket option is ignored, so every profile except `off` shipped a
/// knob the UI named and the engine dropped. `settings.noises` is the live key
/// — which is why the values now have to be loadable.
struct MaskingOutboundPlacementTests {
    private func server() -> ProxyServer {
        ProxyServer(name: "S", proto: .vless, address: "e.com", port: 443,
                    credential: "u", network: .tcp, security: .none)
    }

    private func config(_ anti: AntiCensorshipOptions) throws -> [[String: Any]] {
        try XrayConfigBuilder().makeConfig(server: server(), anti: anti)["outbounds"] as! [[String: Any]]
    }

    private func outbound(_ cfg: [[String: Any]], _ tag: String) -> [String: Any]? {
        cfg.first { $0["tag"] as? String == tag }
    }

    @Test func noisesRideOnSettingsNotSockopt() throws {
        let cfg = try config(.recommended)
        let dialer = try #require(outbound(cfg, "fragment"), "masking dialer should exist")
        let settings = try #require(dialer["settings"] as? [String: Any])
        let noises = try #require(settings["noises"] as? [[String: Any]],
                                "junk packets must be emitted in settings.noises")
        #expect(!noises.isEmpty)
        #expect(noises.allSatisfy { $0["type"] != nil && $0["packet"] != nil && $0["delay"] != nil })
        #expect(settings["fragment"] != nil, "fragmentation must be emitted in settings.fragment")
        let sockopt = (dialer["streamSettings"] as? [String: Any])?["sockopt"] as? [String: Any]
        #expect(sockopt?["noises"] == nil, "sockopt.noises is an unknown key — never emit it")
        let proxy = try #require(outbound(cfg, "proxy"))
        let proxySockopt = (proxy["streamSettings"] as? [String: Any])?["sockopt"] as? [String: Any]
        #expect(proxySockopt?["dialerProxy"] as? String == "fragment")
    }

    /// A profile whose masking is entirely unreadable must not produce a
    /// masking dialer at all: an empty `settings` object would be emitted, and
    /// a fragment-only dialer with a rejected fragment is a config that dies.
    @Test func unreadableMaskingProducesNoDialer() throws {
        let options = AntiCensorshipOptions(
            fragment: .init(packets: "abc", length: "0-200", interval: "10"),
            noises: [.init(type: "hex", packet: "zz", delay: "abc")])
        #expect(outbound(try config(options), "fragment") == nil)
        let proxy = try #require(outbound(try config(options), "proxy"))
        let sockopt = (proxy["streamSettings"] as? [String: Any])?["sockopt"] as? [String: Any]
        #expect(sockopt?["dialerProxy"] == nil, "nothing to chain to")
    }

    /// Partially readable masking keeps what loads, and the proxy still chains.
    @Test func partialMaskingKeepsTheLoadablePart() throws {
        let options = AntiCensorshipOptions(
            fragment: .init(packets: "abc", length: "0-200", interval: "10"),
            noises: [.init(type: "hex", packet: "zz", delay: "abc"),
                     .init(type: "rand", packet: "50-100", delay: "10-16")])
        let dialer = try #require(outbound(try config(options), "fragment"))
        let settings = try #require(dialer["settings"] as? [String: Any])
        #expect(settings["fragment"] == nil, "the rejected fragment must not be emitted")
        let noises = try #require(settings["noises"] as? [[String: Any]])
        #expect(noises.count == 1)
        #expect(noises[0]["type"] as? String == "rand")
    }

    /// Noises alone (no fragment) still earn the dialer — this is the case the
    /// old `anti.fragment != nil` condition threw away.
    @Test func noisesWithoutFragmentStillDial() throws {
        let options = AntiCensorshipOptions(fragment: nil,
                                            noises: [.init(type: "str", packet: "hi", delay: "10")])
        let dialer = try #require(outbound(try config(options), "fragment"))
        let settings = try #require(dialer["settings"] as? [String: Any])
        #expect(settings["fragment"] == nil)
        #expect((settings["noises"] as? [[String: Any]])?.count == 1)
    }
}
