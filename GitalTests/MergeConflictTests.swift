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

    // A stopped rebase (merge backend) also leaves CHERRY_PICK_HEAD behind;
    // it must classify as a rebase, or Continue would run the wrong command.
    @Test func rebaseMarkersWinOverCherryPickHead() {
        #expect(GitRepository.classifyOperation(
            existingMarkers: ["rebase-merge", "CHERRY_PICK_HEAD"]
        ) == .rebase)
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
}
