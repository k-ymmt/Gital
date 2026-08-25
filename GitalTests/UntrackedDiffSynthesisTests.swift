import Foundation
import Testing
@testable import Gital

/// `DiffParser.untrackedFile` replaces one `git diff --no-index /dev/null`
/// subprocess per untracked file. These tests pin its contract the strongest
/// way available: byte-for-byte equivalence with parsing the real git
/// output it replaced, across the edge cases that shaped the parser.
@MainActor
struct UntrackedDiffSynthesisTests {

    // MARK: - Equivalence against real git

    private func withTempDir(_ body: (URL, GitExecutor) async throws -> Void) async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gital-untracked-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let executor = GitExecutor(workingDirectory: tempRoot)
        _ = try await executor.run(["init"])
        try await body(tempRoot, executor)
    }

    private func gitParsed(_ path: String, executor: GitExecutor) async throws -> [FileDiff] {
        let (output, valid) = try await executor.runChecked(
            ["diff", "--no-index", "--", "/dev/null", path],
            successCodes: [0, 1]
        )
        return DiffParser.parse(output, scope: .untracked, strictUTF8: valid)
    }

    @Test func synthesisMatchesGitAcrossEdgeCases() async throws {
        let cases: [(name: String, bytes: Data)] = [
            ("plain.txt", Data("one\ntwo\nthree\n".utf8)),
            ("no-final-newline.txt", Data("one\ntwo".utf8)),
            ("single-line.txt", Data("only\n".utf8)),
            ("crlf.txt", Data("a\r\nb\r\n".utf8)),
            ("empty.txt", Data()),
            ("with space.txt", Data("spaced\n".utf8)),
            ("日本語.txt", Data("こんにちは\n".utf8)),
            ("binary.bin", Data([0x00, 0x01, 0x02, 0xff])),
            ("blank-line.txt", Data("\n".utf8)),
        ]
        try await withTempDir { root, executor in
            for entry in cases {
                let data = entry.bytes
                try data.write(to: root.appendingPathComponent(entry.name))
                let fromGit = try await gitParsed(entry.name, executor: executor)
                let synthesized = DiffParser.untrackedFile(path: entry.name, data: data)
                #expect(fromGit.count == 1, "git emits one file diff for \(entry.name)")
                #expect(fromGit.first == synthesized, "synthesis diverges from git for \(entry.name)")
            }
        }
    }

    @Test func invalidUTF8MatchesGitAndDisablesStaging() async throws {
        // 0x80 alone is not valid UTF-8 but contains no NUL, so git treats
        // the file as text and the app decodes it lossily.
        let data = Data([0x68, 0x69, 0x80, 0x0a])
        try await withTempDir { root, executor in
            try data.write(to: root.appendingPathComponent("latin1.txt"))
            let fromGit = try await gitParsed("latin1.txt", executor: executor)
            let synthesized = DiffParser.untrackedFile(path: "latin1.txt", data: data)
            #expect(fromGit.first == synthesized)
            #expect(synthesized.containsInvalidUTF8, "lossily decoded content must not build patches")
        }
    }

    // MARK: - Shape (no git needed)

    @Test func syntheticShape() {
        let diff = DiffParser.untrackedFile(path: "dir/new.txt", data: Data("a\nb".utf8))
        #expect(diff.path == "dir/new.txt" && diff.scope == .untracked)
        #expect(diff.hunks.count == 1)
        let hunk = diff.hunks[0]
        #expect(hunk.id == "dir/new.txt@h0" && hunk.header == "@@ -0,0 +1,2 @@")
        #expect(hunk.lines.map(\.id) == ["dir/new.txt@0", "dir/new.txt@1"], "line IDs follow the path@n scheme")
        #expect(hunk.lines.allSatisfy { $0.kind == .addition })
        #expect(hunk.lines.last?.noNewline == true)
        #expect(diff.oldBlobHash == "0000000")
    }

    @Test func binaryAndEmptySynthesis() {
        let binary = DiffParser.untrackedFile(path: "x.bin", data: Data([0x00, 0x01]))
        #expect(binary.isBinary && binary.hunks.isEmpty)
        let empty = DiffParser.untrackedFile(path: "empty", data: Data())
        #expect(!empty.isBinary && empty.hunks.isEmpty, "empty file is a header-only diff, like git's")
    }
}
