import Foundation
import Synchronization
import Testing

@testable import Gital

/// The work-avoidance paths of history loading: `refreshLog` reusing the
/// loaded log while refs are unchanged, the Commit tab skipping the
/// whole-commit patch, and the `--git-path` cache.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HistoryLoadingPerformanceTests {
    /// Temp repo with two commits on `main`.
    private func withRepo(_ body: (GitExecutor, RepoViewModel) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gital-history-perf-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let git = GitExecutor(workingDirectory: root)
        _ = try await git.run(["init", "-b", "main"])
        _ = try await git.run(["config", "user.name", "Gital Tests"])
        _ = try await git.run(["config", "user.email", "tests@example.com"])
        _ = try await git.run(["config", "commit.gpgsign", "false"])
        for subject in ["base", "second"] {
            try Data("\(subject)\n".utf8).write(to: root.appendingPathComponent("file.txt"))
            _ = try await git.run(["add", "."])
            _ = try await git.run(["commit", "-m", subject])
        }
        let model = RepoViewModel(repository: GitRepository(root: root), watchFileSystem: false)
        defer { model.close() }
        try await body(git, model)
    }

    /// Waits for state a fire-and-forget model Task produces.
    private func waitUntil(_ condition: () -> Bool) async throws {
        while !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func refreshLogReusesLoadedLogWhileRefsAreUnchanged() async throws {
        try await withRepo { _, model in
            await model.refreshLog()
            #expect(model.commits.map(\.subject) == ["second", "base"])
            // A sentinel the skip leaves alone and a reload would replace.
            model.commits = Array(model.commits.prefix(1))
            await model.refreshLog()
            #expect(model.commits.count == 1, "unchanged refs skip the git log re-run")
        }
    }

    @Test func refreshLogReloadsWhenARefMoves() async throws {
        try await withRepo { git, model in
            await model.refreshLog()
            _ = try await git.run(["commit", "--allow-empty", "-m", "third"])
            await model.refreshLog()
            #expect(model.commits.first?.subject == "third")
            // A new tag decorates an existing commit without moving HEAD.
            _ = try await git.run(["tag", "v1", "HEAD~1"])
            await model.refreshLog()
            #expect(model.commits[1].refs.contains { $0.kind == .tag && $0.name == "v1" })
            // Detached HEAD on the same commit changes the HEAD decoration.
            _ = try await git.run(["checkout", "--detach", "HEAD"])
            await model.refreshLog()
            #expect(!model.commits[0].refs.contains { $0.kind == .head })
        }
    }

    @Test func refreshLogReloadsOnceTheReuseWindowExpires() async throws {
        try await withRepo { _, model in
            await model.refreshLog()
            let stored = try #require(model.logRefsFingerprint)
            model.commits = Array(model.commits.prefix(1))
            model.logRefsFingerprint = (stored.value, stored.loadedAt - RepoViewModel.logReuseWindow)
            await model.refreshLog()
            #expect(model.commits.count == 2, "relative dates must not stay stale forever")
        }
    }

    @Test func commitTabSkipsThePatchUntilFilesTabOpens() async throws {
        try await withRepo { _, model in
            await model.refreshLog()
            let hash = try #require(model.commits.first?.hash)
            model.commitDetailTab = .commit
            model.selectedCommitHash = hash
            try await waitUntil { model.commitDetail?.hash == hash }
            #expect(!model.commitFiles.isEmpty)
            #expect(model.commitDiffsHash == nil, "the Commit tab never fetches the patch")
            #expect(model.commitDiffs.isEmpty)

            model.commitDetailTab = .files
            try await waitUntil { model.commitDiffsHash == hash }
            #expect(model.commitDiffs.map(\.path) == ["file.txt"])
        }
    }

    @Test func filesTabLoadsThePatchForEachNewSelection() async throws {
        try await withRepo { _, model in
            await model.refreshLog()
            let hashes = model.commits.map(\.hash)
            model.commitDetailTab = .files
            for hash in hashes {
                model.selectedCommitHash = hash
                try await waitUntil { model.commitDiffsHash == hash }
                #expect(model.selectedCommitDiff?.path == "file.txt")
            }
        }
    }

    @Test func gitPathResolutionsAreCachedAndBatched() async throws {
        try await withRepo { _, model in
            let repository = model.repository
            let urls = try await repository.gitPathURLs(["MERGE_HEAD", "rebase-merge"])
            #expect(urls.map(\.lastPathComponent) == ["MERGE_HEAD", "rebase-merge"])
            #expect(repository.gitPathCache.withLock { $0.count } == 2)
            let single = try await repository.gitPathURL("rebase-merge")
            #expect(single == urls[1])
            #expect(try await repository.pendingOperation() == nil)
        }
    }
}
