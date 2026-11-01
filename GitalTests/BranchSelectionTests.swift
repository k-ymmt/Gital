import Foundation
import Testing

@testable import Gital

/// Sidebar ref selection against a real repository: clicking a local
/// branch, a remote-tracking branch, or a tag highlights that row and moves
/// the History selection to its tip — paging deeper history in when the tip
/// isn't loaded yet.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BranchSelectionTests {
    /// Repo with commits `base` → `second` → `third` on `main`, a bare
    /// `origin` whose `main` stopped at `second`, and tag `v1` on `base`.
    private func withRepo(_ body: (RepoViewModel, _ hashes: [String: String]) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gital-selection-tests-\(UUID().uuidString)")
        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("gital-selection-remote-\(UUID().uuidString).git")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: remote)
        }

        let git = GitExecutor(workingDirectory: root)
        _ = try await git.run(["init", "-b", "main"])
        _ = try await git.run(["config", "user.name", "Gital Tests"])
        _ = try await git.run(["config", "user.email", "tests@example.com"])
        _ = try await git.run(["config", "commit.gpgsign", "false"])
        var hashes: [String: String] = [:]
        for subject in ["base", "second"] {
            try Data("\(subject)\n".utf8).write(to: root.appendingPathComponent("file.txt"))
            _ = try await git.run(["add", "."])
            _ = try await git.run(["commit", "-m", subject])
            hashes[subject] = try await git.run(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try await git.run(["tag", "v1", hashes["base"]!])
        _ = try await git.run(["clone", "--bare", root.path, remote.path])
        _ = try await git.run(["remote", "add", "origin", remote.path])
        _ = try await git.run(["fetch", "origin"])
        try Data("third\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        _ = try await git.run(["commit", "-am", "third"])
        hashes["third"] = try await git.run(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)

        let model = RepoViewModel(repository: GitRepository(root: root), watchFileSystem: false)
        defer { model.close() }
        await model.refreshLog()
        await model.refreshRefs()
        try await body(model, hashes)
    }

    @Test func remoteBranchSelectionHighlightsRowAndSelectsItsTip() async throws {
        try await withRepo { model, hashes in
            let origin = try #require(model.remotes.first { $0.name == "origin" })
            let main = try #require(origin.branches.first { $0.name == "main" })
            #expect(main.tipHash == hashes["second"], "remote branch carries the fetched tip")

            model.selectRemoteBranch(main, remote: "origin")
            #expect(model.selectedCommitHash == hashes["second"])
            #expect(model.isRemoteBranchRowHighlighted(remote: "origin", branch: "main"))
            #expect(model.highlightedBranchName == nil, "the current local branch loses its fallback highlight")
            #expect(model.selectedTagName == nil)
        }
    }

    @Test func movingHistorySelectionOffTheTipDropsRemoteSelection() async throws {
        try await withRepo { model, hashes in
            let main = try #require(model.remotes.first { $0.name == "origin" }?.branches.first { $0.name == "main" })
            model.selectRemoteBranch(main, remote: "origin")
            model.selectedCommitHash = hashes["third"]
            #expect(model.selectedRemoteBranch == nil)
            #expect(!model.isRemoteBranchRowHighlighted(remote: "origin", branch: "main"))
            #expect(model.highlightedBranchName == "main", "the current branch's fallback highlight returns")
        }
    }

    @Test func selectionsAreMutuallyExclusiveAcrossRefKinds() async throws {
        try await withRepo { model, hashes in
            let main = try #require(model.remotes.first { $0.name == "origin" }?.branches.first { $0.name == "main" })
            let tag = try #require(model.tags.first { $0.name == "v1" })
            let local = try #require(model.branches.first { $0.name == "main" })

            model.selectRemoteBranch(main, remote: "origin")
            model.selectTag(tag)
            #expect(model.selectedRemoteBranch == nil)
            #expect(model.selectedTagName == "v1")
            #expect(model.selectedCommitHash == hashes["base"])

            model.selectBranch(local)
            #expect(model.selectedTagName == nil)
            #expect(model.selectedBranchName == "main")
            #expect(model.selectedCommitHash == hashes["third"])

            model.selectRemoteBranch(main, remote: "origin")
            #expect(model.selectedBranchName == nil)
            #expect(model.selectedBranchNames.isEmpty)
            #expect(model.highlightedBranchName == nil)
        }
    }

    // The History list is paged; a ref whose tip is older than the loaded
    // page must pull that history in or the list has nothing to scroll to.
    @Test func ensureCommitLoadedPagesHistoryInUntilTheTipIsPresent() async throws {
        try await withRepo { model, hashes in
            // Simulate a partially loaded log: only the newest commit is in.
            model.commits = Array(model.commits.prefix(1))
            model.hasMoreCommits = true
            #expect(!model.commits.contains { $0.hash == hashes["base"] })

            await model.ensureCommitLoaded(hashes["base"]!)
            #expect(model.commits.map(\.hash) == [hashes["third"], hashes["second"], hashes["base"]])
            #expect(model.hasMoreCommits == false, "a short page means the log is exhausted")
            #expect(model.graph.rows.count == 3, "graph is laid out over the paged-in history")
        }
    }

    @Test func ensureCommitLoadedIsANoOpWhenAlreadyLoaded() async throws {
        try await withRepo { model, hashes in
            let before = model.commits
            await model.ensureCommitLoaded(hashes["base"]!)
            #expect(model.commits == before)
        }
    }
}
