import Foundation
import Testing

@testable import Gital

/// Semantics of `RepoViewModel.autoFetchTick` against real repositories.
/// The view models are created without file watching: FSEvents refreshes
/// firing mid-test would race the assertions about which loads ran.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AutoFetchTickTests {
    /// Temp repo with one commit on `main`; the model is torn down after.
    private func withRepo(_ body: (GitExecutor, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gital-autofetch-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let git = GitExecutor(workingDirectory: root)
        _ = try await git.run(["init", "-b", "main"])
        _ = try await git.run(["config", "user.name", "Gital Tests"])
        _ = try await git.run(["config", "user.email", "tests@example.com"])
        _ = try await git.run(["config", "commit.gpgsign", "false"])
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        _ = try await git.run(["add", "."])
        _ = try await git.run(["commit", "-m", "base"])

        try await body(git, root)
    }

    /// `withRepo` plus a bare clone wired up as `origin`. The clone lives
    /// beside the repo, not inside it — status must never see it as an
    /// untracked directory.
    private func withRemoteBackedRepo(_ body: (GitExecutor, URL) async throws -> Void) async throws {
        try await withRepo { git, root in
            let remote = root.deletingLastPathComponent()
                .appendingPathComponent("gital-autofetch-remote-\(UUID().uuidString).git")
            defer { try? FileManager.default.removeItem(at: remote) }
            _ = try await git.run(["clone", "--bare", root.path, remote.path])
            _ = try await git.run(["remote", "add", "origin", remote.path])
            try await body(git, root)
        }
    }

    @Test func tickSkipsWhileUserSyncIsRunning() async throws {
        try await withRepo { _, root in
            let model = RepoViewModel(repository: GitRepository(root: root), watchFileSystem: false)
            defer { model.close() }
            model.isSyncing = true
            await model.autoFetchTick(interval: 60)
            // Skipped entirely: no gate stamp (the next tick retries) and no
            // refresh.
            #expect(model.lastAutoFetch == nil)
            #expect(model.commits.isEmpty)
        }
    }

    @Test func tickWithoutRemotesStampsGateAndSkipsRefresh() async throws {
        try await withRepo { _, root in
            // No remotes configured: the fetch succeeds but cannot change
            // anything, so the tick stamps the gate and skips every refresh.
            let model = RepoViewModel(repository: GitRepository(root: root), watchFileSystem: false)
            defer { model.close() }
            await model.autoFetchTick(interval: 60)
            #expect(model.lastAutoFetch != nil)
            #expect(model.commits.isEmpty)
            #expect(model.errorMessage == nil)
        }
    }

    @Test func remoteChangeRefreshesStatusLogAndRefs() async throws {
        try await withRemoteBackedRepo { git, root in
            let model = RepoViewModel(repository: GitRepository(root: root), watchFileSystem: false)
            defer { model.close() }
            // Baseline tick: origin/main is new knowledge → refresh runs.
            await model.autoFetchTick(interval: 60)
            #expect(model.commits.count == 1)
            #expect(model.status.branch == "main")
            #expect(model.branches.contains { $0.name == "main" })

            // Simulate the remote moving ahead of our knowledge: the new
            // commit exists on the remote (pushed), and the stale tracking
            // ref is dropped so the next fetch has to re-learn it.
            try Data("more\n".utf8).write(to: root.appendingPathComponent("file2.txt"))
            _ = try await git.run(["add", "."])
            _ = try await git.run(["commit", "-m", "second"])
            _ = try await git.run(["push", "origin", "main"])
            _ = try await git.run(["update-ref", "-d", "refs/remotes/origin/main"])
            model.lastAutoFetch = nil
            await model.autoFetchTick(interval: 60)
            #expect(model.commits.count == 2)
        }
    }

    @Test func noRemoteChangeSkipsRefreshAndWritesNoFetchHead() async throws {
        try await withRemoteBackedRepo { git, root in
            let model = RepoViewModel(repository: GitRepository(root: root), watchFileSystem: false)
            defer { model.close() }
            await model.autoFetchTick(interval: 60)
            #expect(model.commits.count == 1)

            // A local-only commit changes the log — but not the remote, so
            // the next tick must skip the refresh and never pick it up.
            try Data("more\n".utf8).write(to: root.appendingPathComponent("file2.txt"))
            _ = try await git.run(["add", "."])
            _ = try await git.run(["commit", "-m", "local only"])
            model.lastAutoFetch = nil
            await model.autoFetchTick(interval: 60)
            #expect(model.commits.count == 1)

            // --no-write-fetch-head: neither tick left a FETCH_HEAD behind,
            // so the FSEvents watcher (off in tests) would have stayed quiet.
            let fetchHead = root.appendingPathComponent(".git/FETCH_HEAD").path
            #expect(!FileManager.default.fileExists(atPath: fetchHead))
        }
    }

    @Test func failedFetchStampsGateStaysSilentAndSkipsRefresh() async throws {
        try await withRepo { git, root in
            _ = try await git.run(["remote", "add", "origin", "/nonexistent/gital-no-such-remote"])
            let model = RepoViewModel(repository: GitRepository(root: root), watchFileSystem: false)
            defer { model.close() }
            await model.autoFetchTick(interval: 60)
            // The failed attempt still counts for the gate — otherwise every
            // tick while offline would hot-retry against the dead remote …
            #expect(model.lastAutoFetch != nil)
            // … but it must not alert (offline is normal here) and must not
            // refresh (nothing was fetched).
            #expect(model.errorMessage == nil)
            #expect(model.commits.isEmpty)
        }
    }

    @Test func secondTickWithinIntervalDoesNotFetchAgain() async throws {
        try await withRepo { _, root in
            let model = RepoViewModel(repository: GitRepository(root: root), watchFileSystem: false)
            defer { model.close() }
            await model.autoFetchTick(interval: 3600)
            let stamp = model.lastAutoFetch
            #expect(stamp != nil)
            await model.autoFetchTick(interval: 3600)
            #expect(model.lastAutoFetch == stamp)
        }
    }
}
