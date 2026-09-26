import Foundation
import Testing
import LoaderShared

/// The root helper must never execute a binary a user-level process could swap.
struct EngineBinaryPolicyTests {
    private let installed = EngineBinaryPolicy.installedAWGEngine
    private let rootExecutable = EngineBinaryPolicy.FileFacts(isRegularFile: true, ownerID: 0, permissions: 0o755)

    @Test func installedRootOwnedEngineRuns() {
        #expect(EngineBinaryPolicy.refusal(path: installed, allowed: [installed], facts: rootExecutable) == nil)
    }

    @Test func pathsOutsideTheAllowListAreRefused() {
        for path in ["/opt/homebrew/bin/amneziawg-go", "/Applications/Anemia.app/Contents/Resources/amneziawg-go",
                     "/tmp/amneziawg-go", "/Library/PrivilegedHelperTools/../../tmp/amneziawg-go"] {
            let reason = EngineBinaryPolicy.refusal(path: path, allowed: [installed], facts: rootExecutable)
            #expect(reason?.contains("installed with the helper") == true, "\(path)")
        }
    }

    @Test func anythingNonRootCouldChangeIsRefused() {
        let cases: [(EngineBinaryPolicy.FileFacts?, String)] = [
            (nil, "not installed"),
            (.init(isRegularFile: false, ownerID: 0, permissions: 0o755), "not a regular file"),
            (.init(isRegularFile: true, ownerID: 501, permissions: 0o755), "not owned by root"),
            (.init(isRegularFile: true, ownerID: 0, permissions: 0o775), "writable by non-root"),
            (.init(isRegularFile: true, ownerID: 0, permissions: 0o757), "writable by non-root"),
            (.init(isRegularFile: true, ownerID: 0, permissions: 0o644), "not executable"),
        ]
        for (facts, expected) in cases {
            let reason = EngineBinaryPolicy.refusal(path: installed, allowed: [installed], facts: facts)
            #expect(reason?.contains(expected) == true, "\(String(describing: facts)) → \(reason ?? "allowed")")
        }
    }

    /// Real files: a user-owned binary and a symlink to it are both refused.
    @Test func realFilesystemFacts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anemia-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let binary = dir.appendingPathComponent("amneziawg-go")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let link = dir.appendingPathComponent("engine-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)

        let userFacts = try #require(EngineBinaryPolicy.facts(at: binary.path))
        #expect(userFacts.isRegularFile)
        #expect(userFacts.permissions & 0o777 == 0o755)
        if getuid() != 0 {
            #expect(EngineBinaryPolicy.refusal(path: binary.path, allowed: [binary.path], facts: userFacts)?
                .contains("not owned by root") == true)
        }
        let linkFacts = try #require(EngineBinaryPolicy.facts(at: link.path))
        #expect(!linkFacts.isRegularFile)
        #expect(EngineBinaryPolicy.facts(at: dir.appendingPathComponent("missing").path) == nil)
    }
}
