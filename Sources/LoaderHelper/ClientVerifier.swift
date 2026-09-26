import Foundation
import Security

/// Verifies that a connecting XPC client is the genuine, signed Loader app
/// before the helper will act on its requests.
///
/// The code requirement is supplied via the `LOADER_CLIENT_REQUIREMENT` env var
/// (set in the helper's LaunchDaemon plist for production), e.g.:
///   anchor apple generic and identifier "com.loader.vpn"
///   and certificate leaf[subject.OU] = "TEAMID"
///
/// A missing requirement REJECTS the connection: this daemon runs as root and
/// exposes route-table, DNS, proxy and pf controls — failing closed on a
/// misconfigured plist is the only safe default. Dev installs set the env var
/// in Scripts/install-helper-dev.sh, so local development is unaffected.
///
/// Dev builds use an identifier-only requirement, which an ad-hoc signature can
/// satisfy (`codesign -s - -i <id>`); that is the accepted personal-machine
/// risk. Release builds must ship a TeamID-anchored requirement instead.
enum ClientVerifier {
    static let requirement: String? = ProcessInfo.processInfo.environment["LOADER_CLIENT_REQUIREMENT"]

    static func isValid(_ connection: NSXPCConnection) -> Bool {
        guard let req = requirement, !req.isEmpty else {
            FileHandle.standardError.write(Data(
                "[helper] ERROR: no LOADER_CLIENT_REQUIREMENT set — rejecting client (fail closed)\n".utf8))
            return false
        }

        // Identify the caller by pid, then check its code signature. A pid
        // can be recycled between the connect and this check, so this is only
        // the accept-time gate: `enforce(on:)` binds the same requirement to
        // the connection, and the XPC runtime checks it against the audit
        // token of every message.
        let pid = connection.processIdentifier
        let attrs: CFDictionary = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary

        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, SecCSFlags(), &code) == errSecSuccess,
              let code else { return false }

        var secReq: SecRequirement?
        guard SecRequirementCreateWithString(req as CFString, SecCSFlags(), &secReq) == errSecSuccess,
              let secReq else { return false }

        return SecCodeCheckValidity(code, SecCSFlags(), secReq) == errSecSuccess
    }

    /// Have the XPC runtime check the requirement on every incoming message
    /// against the sender's audit token (NSXPCConnection, macOS 13+); a
    /// message from any other process invalidates the connection. Closes the
    /// pid-reuse window the accept-time `isValid` check leaves open.
    static func enforce(on connection: NSXPCConnection) {
        guard let req = requirement, !req.isEmpty else { return }
        connection.setCodeSigningRequirement(req)
    }
}
