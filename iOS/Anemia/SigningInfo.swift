import Foundation

/// The installed bundle as GBox left it. Nothing is hard-coded, because a
/// signer may rewrite bundle IDs.
enum AppBundle {
    /// The embedded packet-tunnel extension.
    static var tunnelExtension: Bundle? {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
        else { return nil }
        return items
            .filter { $0.pathExtension == "appex" }
            .compactMap(Bundle.init(url:))
            .first { bundle in
                let info = bundle.infoDictionary?["NSExtension"] as? [String: Any]
                return info?["NSExtensionPointIdentifier"] as? String == "com.apple.networkextension.packet-tunnel"
            }
    }

    static var tunnelBundleID: String {
        tunnelExtension?.bundleIdentifier ?? (Bundle.main.bundleIdentifier ?? "") + ".tunnel"
    }

    /// "1.0 (12)", or "dev" for a build without them.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case (let short?, let build?): return "\(short) (\(build))"
        case (let short?, nil): return short
        default: return "dev"
        }
    }
}

/// The parts of an `embedded.mobileprovision` that decide whether a VPN can
/// run. The file is a CMS envelope around an XML plist; the plist is cut out
/// without verifying the envelope — iOS has already done that at install.
struct ProvisioningProfile {
    let name: String
    let appID: String
    let expires: Date?
    let networkExtensions: [String]

    var allowsPacketTunnel: Bool { networkExtensions.contains("packet-tunnel-provider") }

    init?(bundleURL: URL) {
        guard let data = try? Data(contentsOf: bundleURL.appendingPathComponent("embedded.mobileprovision")),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil
              ) as? [String: Any]
        else { return nil }

        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        name = plist["Name"] as? String ?? "?"
        appID = entitlements["application-identifier"] as? String ?? "?"
        expires = plist["ExpirationDate"] as? Date
        networkExtensions = entitlements["com.apple.developer.networking.networkextension"] as? [String] ?? []
    }
}
