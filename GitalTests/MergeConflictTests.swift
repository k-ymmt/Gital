import Foundation
import Testing
@testable import Gital

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MergeConflictTests {

    // MARK: - Operation classification (pure)

    @Test func noMarkersMeansNoOperation() {
        #expect(GitRepository.classifyOperation(existingMarkers: []) == nil)
    }

    @Test func classifiesEachMarker() {
        #expect(GitRepository.classifyOperation(existingMarkers: ["MERGE_HEAD"]) == .merge)
        #expect(GitRepository.classifyOperation(existingMarkers: ["rebase-merge"]) == .rebase)
        #expect(GitRepository.classifyOperation(existingMarkers: ["rebase-apply"]) == .rebase)
        #expect(GitRepository.classifyOperation(existingMarkers: ["CHERRY_PICK_HEAD"]) == .cherryPick)
        #expect(GitRepository.classifyOperation(existingMarkers: ["REVERT_HEAD"]) == .revert)
    }

    // Defensive priority: older gits left CHERRY_PICK_HEAD behind during a
    // stopped rebase (and --rebase-merges can leave MERGE_HEAD); those must
    // classify as a rebase, or Continue would run the wrong command.
    @Test func rebaseMarkersWinOverSequencerHeads() {
        #expect(GitRepository.classifyOperation(
            existingMarkers: ["rebase-merge", "CHERRY_PICK_HEAD"]
        ) == .rebase)
        #expect(GitRepository.classifyOperation(
            existingMarkers: ["rebase-merge", "MERGE_HEAD"]
        ) == .rebase)
    }

    // MARK: - Conflict-marker detection / unmerged-entry parsing (pure)

    @Test func detectsConflictMarkers() {
        let conflicted = "line\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\nend\n"
        #expect(GitRepository.hasConflictMarkers(in: Data(conflicted.utf8)))
        // Both fence lines are required — a lone "<<<<<<<" (e.g. heredoc-ish
        // content) must not trigger the warning.
        #expect(!GitRepository.hasConflictMarkers(in: Data("a\n<<<<<<< HEAD\nb\n".utf8)))
        #expect(!GitRepository.hasConflictMarkers(in: Data("plain\ncontent\n".utf8)))
    }

    @Test func parsesUnmergedEntries() {
        let output = "100644 aaaa 1\tfile.txt\u{0}100644 bbbb 2\tfile.txt\u{0}100644 cccc 3\tfile.txt\u{0}100644 dddd 2\tdir/with space.txt\u{0}"
        let entries = GitRepository.parseUnmergedEntries(output)
        #expect(entries.count == 4)
        #expect(entries.filter { $0.path == "file.txt" }.map(\.stage).sorted() == [1, 2, 3])
        #expect(entries.contains(GitRepository.UnmergedEntry(path: "dir/with space.txt", stage: 2)))
    }

    // MARK: - Combined diff flagging (pure)

    @Test func combinedDiffIsFlagged() {
        let combined = """
        diff --cc file.txt
        index 1111,2222..0000
        --- a/file.txt
        +++ b/file.txt
        @@@ -1,1 -1,1 +1,5 @@@
        ++<<<<<<< HEAD
         +main
        ++=======
        + feature
        ++>>>>>>> feature
        """
        let diffs = DiffParser.parse(combined, scope: .unstaged)
        #expect(diffs.count == 1)
        #expect(diffs.first?.isCombined == true)

        let plain = """
        diff --git a/file.txt b/file.txt
        --- a/file.txt
        +++ b/file.txt
        @@ -1 +1 @@
        -old
        +new
        """
        #expect(DiffParser.parse(plain, scope: .unstaged).first?.isCombined == false)
    }

    // MARK: - Live repository flows

    /// Builds a repo where `main` and `feature` both rewrote file.txt, so any
    /// merge or rebase between them conflicts.
    private func withConflictingBranches(
        _ body: (GitRepository, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gital-merge-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let git = GitExecutor(workingDirectory: root)
        _ = try await git.run(["init", "-b", "main"])
        _ = try await git.run(["config", "user.name", "Gital Tests"])
        _ = try await git.run(["config", "user.email", "tests@example.com"])
        _ = try await git.run(["config", "commit.gpgsign", "false"])

        func write(_ text: String) throws {
            try Data(text.utf8).write(to: root.appendingPathComponent("file.txt"))
        }
        try write("base\n")
        _ = try await git.run(["add", "."])
        _ = try await git.run(["commit", "-m", "base"])
        _ = try await git.run(["checkout", "-b", "feature"])
        try write("feature\n")
        _ = try await git.run(["commit", "-am", "feature"])
        _ = try await git.run(["checkout", "main"])
        try write("main\n")
        _ = try await git.run(["commit", "-am", "main"])

        try await body(GitRepository(root: root), root)
    }

    @Test func mergeConflictResolveTheirsAndContinue() async throws {
        try await withConflictingBranches { repo, root in
            await #expect(throws: (any Error).self) {
                try await repo.merge(branch: "feature")
            }
            let stopped = try await repo.pendingOperation()
            #expect(stopped == .merge)
            let status = try await repo.status()
            #expect(status.unstaged.contains { $0.path == "file.txt" && $0.status == .conflicted })

            try await repo.resolveConflicts(["file.txt"], using: .theirs)
            let resolvedStatus = try await repo.status()
            #expect(!resolvedStatus.unstaged.contains { $0.status == .conflicted })
            // Resolving stages the file but the merge commit is still pending.
            let stillStopped = try await repo.pendingOperation()
            #expect(stillStopped == .merge)

            try await repo.continueOperation(.merge)
            let after = try await repo.pendingOperation()
            #expect(after == nil)
            let content = try String(contentsOf: root.appendingPathComponent("file.txt"), encoding: .utf8)
            #expect(content == "feature\n")
        }
    }

    @Test func rebaseConflictAbortRestoresState() async throws {
        try await withConflictingBranches { repo, root in
            await #expect(throws: (any Error).self) {
                try await repo.rebase(onto: "feature")
            }
            let stopped = try await repo.pendingOperation()
            #expect(stopped == .rebase)

            try await repo.abortOperation(.rebase)
            let after = try await repo.pendingOperation()
            #expect(after == nil)
            let content = try String(contentsOf: root.appendingPathComponent("file.txt"), encoding: .utf8)
            #expect(content == "main\n")
        }
    }

    // Delete/modify conflict: the side that deleted the file has no index
    // entry, so `checkout --theirs` can't resolve it — resolveConflicts must
    // fall back to accepting the deletion via `git rm`.
    @Test func deleteModifyConflictResolvesToDeletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gital-merge-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let git = GitExecutor(workingDirectory: root)
        _ = try await git.run(["init", "-b", "main"])
        _ = try await git.run(["config", "user.name", "Gital Tests"])
        _ = try await git.run(["config", "user.email", "tests@example.com"])
        _ = try await git.run(["config", "commit.gpgsign", "false"])
        let file = root.appendingPathComponent("file.txt")
        try Data("base\n".utf8).write(to: file)
        _ = try await git.run(["add", "."])
        _ = try await git.run(["commit", "-m", "base"])
        _ = try await git.run(["checkout", "-b", "deleter"])
        _ = try await git.run(["rm", "file.txt"])
        _ = try await git.run(["commit", "-m", "delete"])
        _ = try await git.run(["checkout", "main"])
        try Data("modified\n".utf8).write(to: file)
        _ = try await git.run(["commit", "-am", "modify"])

        let repo = GitRepository(root: root)
        await #expect(throws: (any Error).self) {
            try await repo.merge(branch: "deleter")
        }
        let stopped = try await repo.pendingOperation()
        #expect(stopped == .merge)

        // Theirs deleted the file: resolving to theirs accepts the deletion.
        try await repo.resolveConflicts(["file.txt"], using: .theirs)
        let status = try await repo.status()
        #expect(!status.unstaged.contains { $0.status == .conflicted })
        #expect(!FileManager.default.fileExists(atPath: file.path))

        try await repo.continueOperation(.merge)
        let after = try await repo.pendingOperation()
        #expect(after == nil)
    }

    // A cherry-pick resolved to "ours" becomes empty; `--continue` refuses
    // an empty commit forever, so skip must conclude the operation.
    @Test func emptiedCherryPickIsSkippable() async throws {
        try await withConflictingBranches { repo, root in
            let git = GitExecutor(workingDirectory: root)
            let featureTip = try await git.run(["rev-parse", "feature"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            await #expect(throws: (any Error).self) {
                try await repo.cherryPick(featureTip)
            }
            let stopped = try await repo.pendingOperation()
            #expect(stopped == .cherryPick)

            try await repo.resolveConflicts(["file.txt"], using: .ours)
            try await repo.skipOperation(.cherryPick)
            let after = try await repo.pendingOperation()
            #expect(after == nil)
            let content = try String(contentsOf: root.appendingPathComponent("file.txt"), encoding: .utf8)
            #expect(content == "main\n")
        }
    }
}
