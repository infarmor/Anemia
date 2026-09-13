import Foundation
import LoaderShared

/// Installs / removes the privileged helper LaunchDaemon that opens the utun
/// device and installs the split-tunnel routes for a system-wide VPN.
///
/// Elevation uses a single `osascript ... with administrator privileges` prompt
/// — the sanctioned way for a directly-distributed (non-App-Store) app to gain
/// root for its own helper, with the user approving in the standard macOS
/// password dialog. (The App Store path, SMAppService, needs a Developer ID
/// signature; this build is ad-hoc signed, so we install the LaunchDaemon
/// ourselves, mirroring Scripts/install-helper-dev.sh.)
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
                return "Helper install failed: \(m)"
            }
        }
    }

    /// Install the helper with a single admin prompt. Blocking (waits on the
    /// password dialog) — call off the main actor. Throws `.cancelled` if the
    /// user dismisses the prompt.
    static func install() throws {
        guard let helper = Bundle.main.url(forResource: "LoaderHelper", withExtension: nil),
              let tun2socks = Bundle.main.url(forResource: "tun2socks", withExtension: nil) else {
            throw InstallError.missingBundledFiles
        }

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>MachServices</key><dict><key>\(label)</key><true/></dict>
            <key>Program</key><string>\(helperPath)</string>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><false/>
            <key>EnvironmentVariables</key>
            <dict>
                <!-- Only the genuine app may talk to the root helper: it runs
                     as root, so any local process could otherwise issue XPC
                     start/stop commands. ClientVerifier enforces this code
                     requirement on the app's connection. -->
                <key>LOADER_CLIENT_REQUIREMENT</key>
                <string>identifier "\(LoaderIdentifiers.appBundleID)"</string>
            </dict>
        </dict>
        </plist>
        """

        // Stage the plist + a self-contained install script in the (app-writable)
        // temp dir, then run just the script under admin — this keeps the
        // osascript payload trivial to escape and mirrors the proven dev script.
        let tmp = FileManager.default.temporaryDirectory
        let plistTmp = tmp.appendingPathComponent("\(label).plist")
        try plist.write(to: plistTmp, atomically: true, encoding: .utf8)

        let script = """
        set -e
        mkdir -p '\(toolsDir)'
        install -m 0755 '\(helper.path)' '\(helperPath)'
        install -m 0755 '\(tun2socks.path)' '\(toolsDir)/tun2socks'
        install -m 0644 -o root -g wheel '\(plistTmp.path)' '\(plistPath)'
        launchctl bootout system '\(plistPath)' 2>/dev/null || true
        launchctl bootstrap system '\(plistPath)' || launchctl load '\(plistPath)'
        """
        try runScriptAsAdmin(script, name: "loader-install-helper")
    }

    /// Remove the helper (also a single admin prompt).
    static func uninstall() throws {
        // NOTE: the script path is the only thing interpolated into the
        // AppleScript literal (see runScriptAsAdmin) — the script body itself
        // runs from a temp file, so quoting inside it is unconstrained.
        let tmp = FileManager.default.temporaryDirectory

        // Standalone restore script (a heredoc inside the admin script would
        // need an unindented terminator, which a Swift multi-line literal
        // can't emit).
        let restoreProxy = """
        import json, subprocess, sys
        backup = json.load(open(sys.argv[1]))
        for svc, parts in backup.items():
            if len(parts) != 3:
                continue
            if parts[0] == '1' and parts[1] and parts[2]:
                subprocess.run(['networksetup', '-setsocksfirewallproxy', svc, parts[1], parts[2]], capture_output=True)
                subprocess.run(['networksetup', '-setsocksfirewallproxystate', svc, 'on'], capture_output=True)
            else:
                subprocess.run(['networksetup', '-setsocksfirewallproxystate', svc, 'off'], capture_output=True)
        """
        let restoreProxyURL = tmp.appendingPathComponent("loader-restore-proxy.py")
        try restoreProxy.write(to: restoreProxyURL, atomically: true, encoding: .utf8)

        let script = """
        launchctl bootout system '\(plistPath)' 2>/dev/null || true
        rm -f '\(plistPath)' '\(helperPath)' '\(toolsDir)/tun2socks'
        # Release any kill-switch pf state: bootout's SIGTERM handler can only
        # do async-signal-safe work, so an armed kill switch would otherwise
        # keep the machine blackholed after the helper is gone.
        if [ -r /var/db/Loader/killswitch.token ]; then
            tok=$(cat /var/db/Loader/killswitch.token)
            /sbin/pfctl -X $tok 2>/dev/null || true
        fi
        if [ -f /etc/pf.conf ]; then
            /sbin/pfctl -f /etc/pf.conf 2>/dev/null || true
        else
            /sbin/pfctl -F all 2>/dev/null || true
        fi
        rm -f /var/db/Loader/killswitch.token
        # Restore the user's pre-override SOCKS proxy: apps pointed at the
        # dead engine's port lose the network with nothing left to restore
        # them once the helper is gone.
        if [ -r /var/db/Loader/proxy.backup.json ]; then
            python3 '\(restoreProxyURL.path)' /var/db/Loader/proxy.backup.json 2>/dev/null || true
            rm -f /var/db/Loader/proxy.backup.json
        fi
        """
        defer { try? FileManager.default.removeItem(at: restoreProxyURL) }
        try runScriptAsAdmin(script, name: "loader-uninstall-helper")
    }

    // MARK: - Elevation

    private static func runScriptAsAdmin(_ script: String, name: String) throws {
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        // The command has no double quotes (single-quoted paths only), so the
        // AppleScript string needs no further escaping.
        let osa = "do shell script \"/bin/sh '\(scriptURL.path)'\" with administrator privileges"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", osa]
        let errPipe = Pipe()
        proc.standardError = errPipe
        // nullDevice, not an undrained Pipe: osascript prints the shell
        // script's stdout to this pipe, and an unread pipe filling its 64 KB
        // kernel buffer would block osascript forever — helperBusy stuck on.
        proc.standardOutput = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        try? FileManager.default.removeItem(at: scriptURL)

        guard proc.terminationStatus != 0 else { return }
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // osascript returns "User canceled. (-128)" when the prompt is dismissed.
        if err.contains("-128") || err.lowercased().contains("cancel") {
            throw InstallError.cancelled
        }
        throw InstallError.failed(err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  ? "exit code \(proc.terminationStatus)" : err.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
