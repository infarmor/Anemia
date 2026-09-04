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
/// If no requirement is configured (local dev with unsigned builds), the helper
/// accepts the connection but logs that it is running unverified.
enum ClientVerifier {
    static let requirement: String? = ProcessInfo.processInfo.environment["LOADER_CLIENT_REQUIREMENT"]

    static func isValid(_ connection: NSXPCConnection) -> Bool {
        guard let req = requirement, !req.isEmpty else {
            FileHandle.standardError.write(Data(
                "[helper] WARNING: no LOADER_CLIENT_REQUIREMENT set — accepting client unverified\n".utf8))
            return true
        }

        // Identify the caller by pid, then check its code signature. Known
        // limitation: pid can in theory be recycled between the message send
        // and this check (TOCTOU); the airtight fix — audit tokens — requires
        // the private xpc_connection_get_audit_token API, which an
        // NSXPCListener-based helper cannot reach without private headers.
        // Accepted risk for a personal-use daemon.
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
}
