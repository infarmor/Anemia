import Foundation

/// Which engine binaries the root helper may execute.
///
/// The helper runs the AmneziaWG engine as root, so the binary must be one only
/// root can change: an allow-listed location, a regular file (not a symlink),
/// root-owned, not group/world-writable. A path the client merely *names* — a
/// Homebrew binary, one inside a user-writable app bundle — could be swapped by
/// any process of the logged-in user, turning "connect" into root code
/// execution for whoever replaced it.
public enum EngineBinaryPolicy {
    /// Where the helper installer puts the AmneziaWG engine.
    public static let installedAWGEngine = "/Library/PrivilegedHelperTools/amneziawg-go"

    public struct FileFacts: Sendable, Equatable {
        public var isRegularFile: Bool
        public var ownerID: UInt32
        public var permissions: UInt16

        public init(isRegularFile: Bool, ownerID: UInt32, permissions: UInt16) {
            self.isRegularFile = isRegularFile
            self.ownerID = ownerID
            self.permissions = permissions
        }
    }

    /// lstat-level facts (a symlink reports as not-a-regular-file), or nil
    /// when nothing is there.
    public static func facts(at path: String) -> FileFacts? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return FileFacts(
            isRegularFile: (attributes[.type] as? FileAttributeType) == .typeRegular,
            ownerID: (attributes[.ownerAccountID] as? NSNumber)?.uint32Value ?? .max,
            permissions: (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o777)
    }

    /// Nil when `path` may run as root; otherwise the reason it may not.
    public static func refusal(path: String, allowed: [String], facts: FileFacts?) -> String? {
        guard allowed.contains(path) else {
            return "refusing to run \(path) as root: the AmneziaWG engine must be installed with the helper (Settings → Network → Update Helper)"
        }
        guard let facts else { return "AmneziaWG engine not installed at \(path)" }
        guard facts.isRegularFile else { return "refusing to run \(path) as root: not a regular file" }
        guard facts.permissions & 0o111 != 0 else { return "AmneziaWG engine at \(path) is not executable" }
        guard facts.ownerID == 0 else { return "refusing to run \(path) as root: not owned by root" }
        guard facts.permissions & 0o022 == 0 else {
            return "refusing to run \(path) as root: writable by non-root users"
        }
        return nil
    }
}
