import Foundation
import Testing

@testable import LoaderApp

/// `NetworkHealthScan` reads DNS and proxy state per service, so a name that
/// `networksetup` doesn't recognize is not a loud failure — it is a service the
/// dead-pin scan silently never looked at, on the one machine where the pin is
/// most likely to be (a disabled service is where an old session left its
/// settings behind). The marker for a disabled service is not part of the name,
/// and trimming before dropping it put a leading space back in.
struct NetworkServiceNameTests {
    private let listing = """
    An asterisk (*) denotes that a network service is disabled.
    Wi-Fi
    * Thunderbolt Ethernet
    USB 10/100/1000 LAN
    """

    @Test func disabledMarkerIsNotPartOfTheName() {
        let names = NetworkHealthScan.parseServiceNames(listing)
        #expect(names == ["Wi-Fi", "Thunderbolt Ethernet", "USB 10/100/1000 LAN"])
        #expect(!names.contains { $0 != $0.trimmingCharacters(in: .whitespaces) })
    }

    /// The ordered listing (`-listallhardwareports` style, and what
    /// `networksetup` itself prints for some services) spells the marker as
    /// `(*)`, which the old single-character drop left as ") Ethernet".
    @Test func parenthesizedMarkerIsHandledToo() {
        let names = NetworkHealthScan.parseServiceNames(
            "header\n(*) iPhone Bridge\nWi-Fi\n\n  *  Thunderbolt Bridge  \n")
        #expect(names == ["iPhone Bridge", "Wi-Fi", "Thunderbolt Bridge"])
    }

    /// A name is passed to `networksetup` as one argv entry, and a leading
    /// space makes the read fail outright (exit 4, "not a recognized network
    /// service") instead of answering empty — measured here against this Mac's
    /// first real service, so the assertion holds on any machine with a
    /// service at all.
    @Test func leadingSpaceIsRejectedByNetworksetup() throws {
        let listing = try #require(XrayController.runCapturing(
            binaryPath: "/usr/sbin/networksetup", arguments: ["-listallnetworkservices"],
            qos: .utility, timeout: 5, mergeStderr: false)?.output)
        let name = try #require(NetworkHealthScan.parseServiceNames(listing).first)
        let pinned = try #require(XrayController.runCapturing(
            binaryPath: "/usr/sbin/networksetup", arguments: ["-getdnsservers", name],
            qos: .utility, timeout: 5, mergeStderr: false))
        #expect(pinned.status == 0, "networksetup rejected its own name «\(name)»")
        let spacey = try #require(XrayController.runCapturing(
            binaryPath: "/usr/sbin/networksetup", arguments: ["-getdnsservers", " " + name],
            qos: .utility, timeout: 5, mergeStderr: false))
        #expect(spacey.status != 0, "a leading space read as a valid service")
    }
}

/// The inventory row says where each engine came from; the Homebrew prefix is
/// CPU-specific, and only recognising one of them labelled an Intel user's
/// brewed engine as the app's own bundle.
struct EngineLabelTests {
    @Test func bothHomebrewPrefixesCount() {
        #expect(EngineInventory.engineLabel("/opt/homebrew/bin/hysteria") == "Homebrew")
        #expect(EngineInventory.engineLabel("/usr/local/bin/hysteria") == "Homebrew")
        #expect(EngineInventory.engineLabel("/Applications/Anemia.app/Contents/Resources/hysteria") == "Bundled")
    }
}
