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

    @Test func successfulTickRefreshesStatusLogAndRefs() async throws {
        try await withRepo { _, root in
            // No remotes configured: `git fetch --all` is a successful no-op.
            let model = RepoViewModel(repository: GitRepository(root: root), watchFileSystem: false)
            defer { model.close() }
            await model.autoFetchTick(interval: 60)
            #expect(model.lastAutoFetch != nil)
            #expect(!model.commits.isEmpty)
            #expect(model.status.branch == "main")
            #expect(model.branches.contains { $0.name == "main" })
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
