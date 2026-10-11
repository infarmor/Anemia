import Foundation
import Testing

@testable import LoaderShared

/// `isLoopbackHost` is the helper's only gate before it writes a system-wide
/// proxy into every network service as root (`HelperService.setSystemProxy`),
/// and it also decides whose proxy the ledger may overwrite. A prefix test on
/// "127." answered yes to `127.attacker.test` — a name, resolved wherever its
/// owner wants, carrying the machine's traffic through a proxy nobody of ours
/// started. `startTunnel`'s SOCKS upstream was already held to an address
/// literal; this is the same rule in one place.
struct LoopbackHostTests {
    @Test func onlyAddressesCountAsLoopback() {
        #expect(NetworkSettingsPolicy.isLoopbackHost("127.0.0.1"))
        #expect(NetworkSettingsPolicy.isLoopbackHost("127.42.1.9"))    // the whole /8
        #expect(NetworkSettingsPolicy.isLoopbackHost("::1"))
        #expect(!NetworkSettingsPolicy.isLoopbackHost("127.attacker.test"))
        #expect(!NetworkSettingsPolicy.isLoopbackHost("localhost"))
        #expect(!NetworkSettingsPolicy.isLoopbackHost("10.0.0.1"))
        #expect(!NetworkSettingsPolicy.isLoopbackHost("128.0.0.1"))
        // A host with a port glued on is not a host: it would reach networksetup
        // as one argv entry and resolve to nothing.
        #expect(!NetworkSettingsPolicy.isLoopbackHost("127.0.0.1:8080"))
        #expect(!NetworkSettingsPolicy.isLoopbackHost(""))
    }

    /// What the app actually writes at both call sites
    /// (`HelperClient.swift:74` and `:145`) — a refusal here would be a broken
    /// coexist mode, not a safety win. There is no constant for it; the literal
    /// in this test is the same string.
    @Test func theAppsOwnPinStillPasses() {
        #expect(NetworkSettingsPolicy.isLoopbackHost("127.0.0.1"))
    }
}
