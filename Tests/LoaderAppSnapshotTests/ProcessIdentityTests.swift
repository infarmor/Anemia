import Darwin
import Foundation
import Testing

@testable import LoaderApp

/// The kill guards in `XrayController`, `HysteriaController` and `ProxyCheck`
/// ask one question before signalling a pid: is this still the process we
/// launched? This pins what "the same path" means — measured with a real child
/// rather than assumed, because the raw compare between `proc_pidpath` and the
/// launch path is false for every symlinked engine, and the first fix people
/// reach for (`resolvingSymlinksInPath()`) is still false under a temporary
/// directory, where `/var/…` resolves to `/private/var/…`.
///
/// A guard that answers false never kills: the SIGKILL rung of the
/// SIGTERM→SIGKILL ladder silently does nothing, and the orphaned engine keeps
/// its ports and its live session.
struct ProcessIdentityTests {
    @Test func pidIdentitySurvivesSymlinksAndPrivatePrefixes() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("loader-pidtest-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let links = root.appendingPathComponent("link", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createDirectory(at: links, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let target = bin.appendingPathComponent("sleep")
        try fm.copyItem(atPath: "/bin/sleep", toPath: target.path)
        let launchedURL = links.appendingPathComponent("sleep")
        try fm.createSymbolicLink(atPath: launchedURL.path, withDestinationPath: target.path)

        let proc = Process()
        proc.executableURL = launchedURL
        proc.arguments = ["30"]
        try proc.run()
        defer { kill(proc.processIdentifier, SIGKILL); proc.waitUntilExit() }

        let launched = try #require(proc.executableURL?.path)
        #expect(EngineProcess.pid(proc.processIdentifier, isExecutable: launched),
                "a symlinked launch path must still identify its own process")
        #expect(EngineProcess.pid(proc.processIdentifier, isExecutable: target.path),
                "and so must the file the symlink points at")

        let reported = try #require(EngineProcess.executablePath(of: proc.processIdentifier))
        #expect(reported == EngineProcess.canonical(target.path))
        // Why the old comparison could not work — the kernel answers with a
        // resolved path, never the one we launched by (NSTemporaryDirectory is
        // under /var, which is a symlink to /private/var).
        #expect(reported != launched, "reported \(reported), launched \(launched)")
        // And a different binary is still a different binary.
        #expect(!EngineProcess.pid(proc.processIdentifier, isExecutable: "/bin/ls"))
    }
}
