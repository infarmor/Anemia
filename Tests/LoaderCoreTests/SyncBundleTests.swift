import Foundation
import Testing
@testable import LoaderCore

/// Moving servers, subscriptions and settings between the Mac and the iPhone.
struct SyncBundleTests {

    private func server(_ name: String, host: String, credential: String = "uuid-1") -> ProxyServer {
        ProxyServer(name: name, proto: .vless, address: host, port: 443,
                    credential: credential, network: .tcp, security: .reality,
                    sni: "www.microsoft.com", realityPublicKey: "PBK", realityShortId: "ab",
                    flow: "xtls-rprx-vision")
    }

    private func sampleState() -> PersistedState {
        var state = PersistedState()
        state.servers = [server("🇳🇱 Amsterdam", host: "nl.example.com"), server("🇩🇪 Frankfurt", host: "de.example.com")]
        state.subscriptions = [Subscription(name: "panel", url: "https://panel.example.com/sub/abc",
                                            servers: [server("🇨🇭 Zurich", host: "ch.example.com")])]
        state.selectedServerID = state.servers[0].id
        state.maskingProfile = .maximum
        state.killSwitchEnabled = true
        state.splitTunnel = SplitTunnelRules(enabled: true, entries: ["ru", "vk.com"])
        state.learnedMasking = ["key": "ruYandex"]
        return state
    }

    /// The QR payload used to be encoded without sorted keys, so dictionaries
    /// like `learnedMasking` went out in a random order — a different (and
    /// sometimes longer, QR-not-fitting) link for identical content.
    @Test func linkPayloadIsKeySorted() throws {
        let bundle = SyncBundle(exportedAt: Date(timeIntervalSince1970: 1_770_000_000), device: "m",
                                servers: [], subscriptions: [],
                                settings: .init(learnedMasking: ["zzz": "off", "aaa": "maximum"]))
        var text = try bundle.link().replacingOccurrences(of: SyncBundle.linkPrefix, with: "")
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        let packed = try #require(Data(base64Encoded: text))
        let json = String(decoding: try (packed as NSData).decompressed(using: .zlib) as Data, as: UTF8.self)
        #expect(json.contains(#""aaa":"maximum","zzz":"off""#), "в раскодированном JSON ключей \(json.count)")
    }

    @Test func fileRoundTrip() throws {
        let bundle = SyncBundle(state: sampleState(), device: "Mac")
        let decoded = try SyncBundle.decode(bundle.fileData())
        #expect(decoded.device == "Mac")
        #expect(decoded.servers.map(\.name) == ["🇳🇱 Amsterdam", "🇩🇪 Frankfurt"])
        #expect(decoded.subscriptions == [.init(name: "panel", url: "https://panel.example.com/sub/abc")])
        #expect(decoded.settings?.maskingProfile == .maximum)
        #expect(decoded.settings?.splitTunnel?.entries == ["ru", "vk.com"])
    }

    @Test func linkRoundTripIsCompactEnoughForAQRCode() throws {
        let bundle = SyncBundle(state: sampleState(), device: "iPhone")
        let link = try bundle.link()
        #expect(link.hasPrefix(SyncBundle.linkPrefix))
        // A QR code holds about 2900 bytes; two servers, a subscription and
        // the settings stay far below.
        #expect(link.count < 1500)
        let decoded = try SyncBundle.fromLink(link)
        #expect(decoded.servers == bundle.servers)
        #expect(decoded.settings == bundle.settings)
        // decode() understands the link form too.
        #expect(try SyncBundle.decode(Data(link.utf8)).device == "iPhone")
    }

    @Test func mergeAddsOnlyWhatIsMissing() {
        let source = sampleState()
        var target = PersistedState()
        // The target already has Amsterdam under another name and id, and the
        // subscription under a trailing slash.
        target.servers = [server("NL-1", host: "nl.example.com")]
        target.subscriptions = [Subscription(name: "mine", url: "https://PANEL.example.com/sub/abc/")]
        let bundle = SyncBundle(state: source, device: "Mac")

        let preview = bundle.preview(against: target, applySettings: false)
        let summary = bundle.merge(into: &target, applySettings: false)
        #expect(preview == summary)
        #expect(summary.addedServers == 1)
        #expect(summary.knownServers == 1)
        #expect(summary.newSubscriptions.isEmpty)
        #expect(summary.knownSubscriptions == 1)
        #expect(!summary.settingsApplied)
        #expect(target.servers.map(\.name) == ["NL-1", "🇩🇪 Frankfurt"])
        // Settings stay unless asked for.
        #expect(target.maskingProfile == PersistedState().maskingProfile)
        #expect(!target.killSwitchEnabled)
    }

    @Test func mergeTakesSettingsWhenAsked() {
        var target = PersistedState()
        target.learnedMasking = ["other": "maximum", "key": "balanced"]
        let summary = SyncBundle(state: sampleState(), device: "Mac").merge(into: &target, applySettings: true)
        #expect(summary.settingsApplied)
        #expect(summary.addedServers == 2)
        #expect(summary.newSubscriptions.count == 1)
        #expect(target.maskingProfile == .maximum)
        #expect(target.killSwitchEnabled)
        #expect(target.splitTunnel.entries == ["ru", "vk.com"])
        // Learned masking merges, the incoming side winning.
        #expect(target.learnedMasking == ["other": "maximum", "key": "ruYandex"])
        // Subscriptions arrive unfetched, for the app to refresh.
        #expect(target.subscriptions.first?.servers.isEmpty == true)
        #expect(target.subscriptions.first?.lastUpdated == nil)
        // An empty device gets a selection.
        #expect(target.selectedServerID != nil)
    }

    @Test func mergeTwiceChangesNothing() {
        let bundle = SyncBundle(state: sampleState(), device: "Mac")
        var target = PersistedState()
        bundle.merge(into: &target, applySettings: true)
        let second = bundle.merge(into: &target, applySettings: false)
        #expect(second.addsNothing)
        #expect(target.servers.count == 2)
        #expect(target.subscriptions.count == 1)
    }

    @Test func aClashingIdGetsANewOne() {
        let original = server("A", host: "a.example.com")
        var clash = server("B", host: "b.example.com")
        clash.id = original.id
        var target = PersistedState()
        target.servers = [original]
        let bundle = SyncBundle(device: "Mac", servers: [clash], subscriptions: [], settings: nil)
        bundle.merge(into: &target, applySettings: false)
        #expect(target.servers.count == 2)
        #expect(Set(target.servers.map(\.id)).count == 2)
    }

    @Test func rejectsForeignAndNewerData() throws {
        #expect(throws: SyncBundle.DecodeError.notABundle) {
            try SyncBundle.decode(Data("{\"hello\": 1}".utf8))
        }
        #expect(throws: SyncBundle.DecodeError.notABundle) {
            try SyncBundle.fromLink("anemia://sync/not-base64!")
        }
        var future = SyncBundle(state: sampleState(), device: "Mac")
        future.version = SyncBundle.formatVersion + 1
        #expect(throws: SyncBundle.DecodeError.newerVersion(SyncBundle.formatVersion + 1)) {
            try SyncBundle.decode(future.fileData())
        }
        #expect(throws: SyncBundle.DecodeError.newerVersion(SyncBundle.formatVersion + 1)) {
            try SyncBundle.fromLink(future.link())
        }
    }

    @Test func recognisesBothForms() throws {
        let bundle = SyncBundle(state: sampleState(), device: "Mac")
        #expect(SyncBundle.looksLikeBundle(try bundle.link()))
        #expect(SyncBundle.looksLikeBundle(String(decoding: try bundle.fileData(), as: UTF8.self)))
        #expect(!SyncBundle.looksLikeBundle("vless://uuid@host:443"))
        #expect(!SyncBundle.looksLikeBundle("https://panel.example.com/sub"))
    }
}
