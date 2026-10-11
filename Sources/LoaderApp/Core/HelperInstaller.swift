import Foundation
import LoaderShared

/// Installs / removes the privileged helper LaunchDaemon that opens the utun
/// device and installs the split-tunnel routes for a system-wide VPN.
///
/// Elevation uses a single `osascript ... with administrator privileges` prompt
/// — the sanctioned way for a directly-distributed (non-App-Store) app to gain
/// root for its own helper, with the user approving in the standard macOS
/// password dialog. (SMAppService needs a Developer ID signature; this build is
/// ad-hoc signed, so the LaunchDaemon is installed directly, mirroring
/// Scripts/install-helper-dev.sh.)
///
/// Every path through here leaves the network in a working state: install
/// stops the old generation (its SIGTERM teardown restores the network) and
/// replays any journal it left before the new daemon starts; uninstall does
/// the same before removing anything; repair works even with no helper
/// installed at all.
enum HelperInstaller {
    static let label = LoaderIdentifiers.helperMachService      // com.loader.vpn.helper
    private static let toolsDir = "/Library/PrivilegedHelperTools"
    private static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    static var helperPath: String { "\(toolsDir)/\(label)" }

    /// Both the binary and the LaunchDaemon must be present to count as installed.
    static var isInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: helperPath) && fm.fileExists(atPath: plistPath)
    }

    enum InstallError: LocalizedError {
        case missingBundledFiles
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .missingBundledFiles:
                return "The bundled helper is missing from the app — rebuild with Scripts/build-app.sh."
            case .cancelled:
                return "Authorization cancelled."
            case .failed(let m):
                return "Helper operation failed: \(m)"
            }
        }
    }

    /// The LaunchDaemon definition (shared with the tests).
    static var launchdPlist: String { HelperLaunchd.plist(helperPath: helperPath) }

    private static func bundled(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: nil)
    }

    /// The AmneziaWG engine ships inside this build.
    static var awgEngineBundled: Bool { bundled("amneziawg-go") != nil }

    /// The root-owned engine copy the helper is allowed to run.
    static var awgEngineInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: EngineBinaryPolicy.installedAWGEngine)
    }

    /// Install the helper with a single admin prompt. Blocking (waits on the
    /// password dialog) — call off the main actor. Throws `.cancelled` if the
    /// user dismisses the prompt.
    static func install() throws {
        guard let helper = bundled("LoaderHelper"), let tun2socks = bundled("tun2socks") else {
            throw InstallError.missingBundledFiles
        }
        let plistTmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(label).plist")
        try launchdPlist.write(to: plistTmp, atomically: true, encoding: .utf8)
        // The AmneziaWG engine runs as root, so it lives where only root can
        // change it (EngineBinaryPolicy) — never run from the app bundle.
        let awgInstall = bundled("amneziawg-go").map {
            "install -m 0755 -o root -g wheel \(q($0.path)) \(q(EngineBinaryPolicy.installedAWGEngine))"
        } ?? "# this build carries no AmneziaWG engine"

        let script = """
        set -e
        mkdir -p \(q(toolsDir))
        # Stop the running generation first: a 0.8+ helper tears the tunnel
        # down and restores DNS/proxy on SIGTERM.
        launchctl bootout system \(q(plistPath)) 2>/dev/null || true
        install -m 0755 \(q(helper.path)) \(q(helperPath))
        install -m 0755 \(q(tun2socks.path)) \(q(toolsDir + "/tun2socks"))
        \(awgInstall)
        install -m 0644 -o root -g wheel \(q(plistTmp.path)) \(q(plistPath))
        # Replay whatever an older generation left (pre-0.8 backups, a pf
        # reference, orphaned bridges) before the new daemon starts.
        \(q(helperPath)) --restore-network >/dev/null 2>&1 || true
        launchctl bootstrap system \(q(plistPath)) || launchctl load \(q(plistPath))
        """
        try runScriptAsAdmin(script, name: "loader-install-helper")
    }

    /// Remove the helper (also a single admin prompt). The network is restored
    /// before anything is deleted.
    static func uninstall() throws {
        let restore = restoreCommands(uninstall: true, reportPath: nil)
        let script = """
        launchctl bootout system \(q(plistPath)) 2>/dev/null || true
        \(restore)
        rm -f \(q(plistPath)) \(q(helperPath)) \(q(toolsDir + "/tun2socks")) \(q(EngineBinaryPolicy.installedAWGEngine))
        """
        try runScriptAsAdmin(script, name: "loader-uninstall-helper")
    }

    /// Repair the network with no usable helper (not installed, outdated, or
    /// unresponsive): one admin prompt runs the bundled helper's
    /// `--restore-network`, falling back to the standalone reset script.
    /// Returns the report of what was changed.
    static func repairNetworkWithAdminPrompt() throws -> String {
        guard bundled("LoaderHelper") != nil || bundled("anemia-network-reset.sh") != nil else {
            throw InstallError.missingBundledFiles
        }
        let report = FileManager.default.temporaryDirectory.appendingPathComponent("loader-repair-report.txt")
        try? FileManager.default.removeItem(at: report)
        let script = """
        # A running daemon generation must not race the CLI over the journal.
        launchctl bootout system \(q(plistPath)) 2>/dev/null || true
        \(restoreCommands(uninstall: false, reportPath: report.path))
        chmod 0644 \(q(report.path)) 2>/dev/null || true
        if [ -f \(q(plistPath)) ]; then launchctl bootstrap system \(q(plistPath)) 2>/dev/null || true; fi
        """
        try runScriptAsAdmin(script, name: "loader-repair-network")
        defer { try? FileManager.default.removeItem(at: report) }
        let text = (try? String(contentsOf: report, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "Network settings restored." : text
    }

    /// Shell lines restoring the network as root: the bundled (always
    /// current) helper binary first, the dependency-free reset script as the
    /// fallback. The *bundled* binary, never the installed one — an older
    /// installed helper doesn't know `--restore-network` and would start
    /// serving XPC inside the admin script, hanging it forever.
    private static func restoreCommands(uninstall: Bool, reportPath: String?) -> String {
        let sink = reportPath.map { "> \(q($0)) 2>&1" } ?? ">/dev/null 2>&1"
        var lines: [String] = []
        let helper = bundled("LoaderHelper")
        let reset = bundled("anemia-network-reset.sh")
        let resetArgs = uninstall ? " --uninstall" : ""
        switch (helper, reset) {
        case let (h?, r?):
            lines.append("\(q(h.path)) --restore-network\(uninstall ? " --uninstall" : "") \(sink) || /bin/bash \(q(r.path))\(resetArgs) \(sink) || true")
        case let (h?, nil):
            lines.append("\(q(h.path)) --restore-network\(uninstall ? " --uninstall" : "") \(sink) || true")
        case let (nil, r?):
            lines.append("/bin/bash \(q(r.path))\(resetArgs) \(sink) || true")
        case (nil, nil):
            lines.append("true")
        }
        if uninstall {
            // The ledger survives only when a restore kept failing; the reset
            // script above handles that case, so the state dir can go.
            lines.append("rm -rf /var/db/Loader")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Elevation

    /// POSIX single-quote a path for the admin shell script.
    private static func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func runScriptAsAdmin(_ script: String, name: String) throws {
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        // The AppleScript literal carries only the script path; escape the two
        // characters that could end or break it.
        let path = scriptURL.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let osa = "do shell script \"/bin/sh \" & quoted form of \"\(path)\" with administrator privileges"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", osa]
        let errPipe = Pipe()
        proc.standardError = errPipe
        // nullDevice, not an undrained Pipe: osascript prints the shell
        // script's stdout, and a full 64 KB pipe would block it forever.
        proc.standardOutput = FileHandle.nullDevice
        try proc.run()
        // Drain stderr to EOF *before* waiting for the exit. osascript writes
        // the failing root script's stderr here, and a child blocked on a full
        // 64 KB pipe never exits: the installer hung in the spinner with the
        // detached thread parked in waitUntilExit, with no error to show.
        // (The wait stays unbounded on purpose — this is where the user may sit
        // on the admin prompt, and a deadline would cancel a legitimate install.)
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard proc.terminationStatus != 0 else { return }
        let err = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // osascript returns "User canceled. (-128)" when the prompt is dismissed.
        if err.contains("-128") || err.lowercased().contains("cancel") {
            throw InstallError.cancelled
        }
        throw InstallError.failed(err.isEmpty ? "exit code \(proc.terminationStatus)" : err)
    }
}
