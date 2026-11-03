import Foundation
import Testing

@testable import Gital

/// `GitBinary` resolves git the way `/usr/bin/env git` would, minus the
/// per-spawn Xcode-shim indirection.
@Suite struct GitBinaryTests {
    @Test func firstExecutableFollowsPATHOrderAndSkipsNonExecutables() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("gital-gitbinary-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let plain = base.appendingPathComponent("plain")
        let first = base.appendingPathComponent("first")
        let second = base.appendingPathComponent("second")
        for directory in [plain, first, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Not executable: env skips it, so must the lookup.
        FileManager.default.createFile(atPath: plain.appendingPathComponent("git").path, contents: Data())
        for directory in [first, second] {
            FileManager.default.createFile(
                atPath: directory.appendingPathComponent("git").path,
                contents: Data("#!/bin/sh\n".utf8),
                attributes: [.posixPermissions: 0o755]
            )
        }
        let path = ["", plain.path, first.path, second.path].joined(separator: ":")
        #expect(GitBinary.firstExecutable(named: "git", inPATH: path)?.path == first.appendingPathComponent("git").path)
        #expect(GitBinary.firstExecutable(named: "git", inPATH: plain.path) == nil)
    }

    @Test func resolvedBinaryIsARealGitNotTheShim() async throws {
        let git = try #require(await GitBinary.resolved())
        #expect(git.path != GitBinary.xcodeShimPath || !FileManager.default.fileExists(atPath: "/usr/bin/xcrun"))
        let output = try await Subprocess.run(executable: git, arguments: ["--version"])
        #expect(output.status == 0)
        #expect(String(decoding: output.stdout, as: UTF8.self).hasPrefix("git version"))
    }
}
