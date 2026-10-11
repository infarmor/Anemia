import Foundation
import LoaderShared

/// What this build can actually run — Settings → About. Scanned off the main
/// actor (one short `xray version` spawn).
struct EngineInventory: Sendable, Equatable {
    enum AWG: Sendable, Equatable {
        /// The root-owned copy the helper is allowed to run is in place.
        case installed
        /// This build carries the engine; the helper hasn't installed it yet.
        case bundled
        case missing
    }

    var xrayVersion: String?
    var tun2socks = false
    var awg: AWG = .missing
    /// "Bundled" / "Homebrew", nil when no hysteria client is reachable.
    var hysteria: String?

    static func scan() async -> EngineInventory {
        await Task.detached(priority: .utility) { scanBlocking() }.value
    }

    private static func scanBlocking() -> EngineInventory {
        let fm = FileManager.default
        var inventory = EngineInventory()
        if let xray = xrayPath(),
           let result = XrayController.runCapturing(binaryPath: xray, arguments: ["version"],
                                                    qos: .utility, timeout: 3),
           result.status == 0 {
            // "Xray 26.3.27 (Xray, Penetrates Everything.) Custom (go1.26.6 darwin/arm64)"
            inventory.xrayVersion = result.output.split(separator: " ").dropFirst().first.map(String.init)
        }
        inventory.tun2socks = Bundle.main.url(forResource: "tun2socks", withExtension: nil) != nil
            || fm.isExecutableFile(atPath: "/Library/PrivilegedHelperTools/tun2socks")
        if fm.isExecutableFile(atPath: EngineBinaryPolicy.installedAWGEngine) {
            inventory.awg = .installed
        } else if Bundle.main.url(forResource: "amneziawg-go", withExtension: nil) != nil {
            inventory.awg = .bundled
        }
        if let hysteria = HysteriaController.resolveBinary() {
            inventory.hysteria = engineLabel(hysteria.path)
        }
        return inventory
    }

    /// Where an engine came from. Both Homebrew prefixes count: naming only
    /// the Apple Silicon one "Homebrew" told an Intel user that the engine
    /// `brew install` had placed in /usr/local/bin was the app's own bundle.
    static func engineLabel(_ path: String) -> String {
        path.hasPrefix("/opt/homebrew") || path.hasPrefix("/usr/local") ? "Homebrew" : "Bundled"
    }

    /// Same search order as XrayController.resolveBinary.
    private static func xrayPath() -> String? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["LOADER_XRAY_PATH"], fm.isExecutableFile(atPath: env) {
            return env
        }
        if let bundled = Bundle.main.url(forResource: "xray", withExtension: nil),
           fm.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }
        return ["/opt/homebrew/bin/xray", "/usr/local/bin/xray"].first { fm.isExecutableFile(atPath: $0) }
    }
}
