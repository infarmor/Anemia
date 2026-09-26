import Foundation

/// The helper's LaunchDaemon definition — one source for the app's installer
/// and the tests (Packaging/LoaderHelper-launchd.plist documents each key;
/// Scripts/install-helper-dev.sh mirrors it for unbundled dev builds).
public enum HelperLaunchd {
    public static let installedHelperPath =
        "/Library/PrivilegedHelperTools/\(LoaderIdentifiers.helperMachService)"
    public static let plistPath =
        "/Library/LaunchDaemons/\(LoaderIdentifiers.helperMachService).plist"

    public static func plist(helperPath: String = installedHelperPath) -> String {
        let label = LoaderIdentifiers.helperMachService
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>MachServices</key><dict><key>\(label)</key><true/></dict>
            <key>Program</key><string>\(helperPath)</string>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
            <key>ProcessType</key><string>Interactive</string>
            <key>ExitTimeOut</key><integer>20</integer>
            <key>EnvironmentVariables</key>
            <dict>
                <key>LOADER_CLIENT_REQUIREMENT</key>
                <string>identifier "\(LoaderIdentifiers.appBundleID)"</string>
            </dict>
        </dict>
        </plist>
        """
    }
}
