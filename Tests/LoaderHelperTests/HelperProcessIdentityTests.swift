import Foundation
import Testing

@testable import LoaderHelper

/// The identity check that gates the SIGKILL after a teardown grace.
/// `proc_pidpath` answers with the path the kernel really used, and a launch
/// through a symlink reports the target — so comparing that with
/// `Process.executableURL.path` (the launch path as written) is false for every
/// symlinked engine, and the kill rung never fires. Measured here, exactly as
/// the app-side `ProcessIdentityTests` measures it for `EngineProcess`.
struct HelperProcessIdentityTests {
    @Test func symlinkedLaunchPathStillIdentifiesTheProcess() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("anemia-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("sleep").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/bin/sleep")
        defer { try? FileManager.default.removeItem(atPath: link)
                try? FileManager.default.removeItem(atPath: directory.path) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: link)
        proc.arguments = ["30"]
        try proc.run()
        defer {
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            proc.waitUntilExit()
        }

        // What the old comparison produced, and why the process survived it.
        #expect(SystemCommand.executablePath(pid: proc.processIdentifier) != link,
                "the kernel reported the launch path after all — nothing for this test to prove")
        #expect(SystemCommand.pid(proc.processIdentifier, isExecutable: link),
                "the resolved comparison lost a process it launched itself")
        #expect(!SystemCommand.pid(proc.processIdentifier, isExecutable: "/bin/cat"),
                "a different executable passed the identity check")
    }

    @Test func canonicalResolvesTheSameAliasesTheKernelDoes() throws {
        // /tmp is an alias of /private/tmp on every macOS install; the kernel
        // reports the latter, so this is the pair a raw compare is bound to miss.
        #expect(SystemCommand.canonical("/tmp") == "/private/tmp")
        #expect(SystemCommand.canonical("/no/such/program") == "/no/such/program")
    }
}
