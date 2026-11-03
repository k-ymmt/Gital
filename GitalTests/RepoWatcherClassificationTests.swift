import Foundation
import Testing
@testable import Gital

/// Which FSEvents bursts re-fetch log and refs. Linked worktrees keep their
/// HEAD, index and reflogs under `<common>/.git/worktrees/<name>/`, outside
/// the worktree root — classified by the "/.git/" substring alone, a commit
/// there (`worktrees/<name>/HEAD`) never counted as ref-affecting.
@MainActor
struct RepoWatcherClassificationTests {
    private let common = "/repo/.git"
    private let gitDir = "/repo/.git/worktrees/wt"

    @Test func linkedWorktreeHeadAndReflogMoveRefs() {
        let dirs = [gitDir, common]
        #expect(RepoWatcher.touchesGitMetadata(["\(gitDir)/HEAD"], gitDirs: dirs))
        #expect(RepoWatcher.touchesGitMetadata(["\(gitDir)/logs/HEAD"], gitDirs: dirs))
        #expect(RepoWatcher.touchesGitMetadata(["\(common)/refs/heads/feature"], gitDirs: dirs))
        #expect(!RepoWatcher.touchesGitMetadata(["\(gitDir)/index"], gitDirs: dirs), "index alone is not ref-affecting")
        #expect(!RepoWatcher.touchesGitMetadata(["/wt/file.swift"], gitDirs: dirs))
    }

    @Test func submoduleGitDirIsClassifiedByItsOwnLayout() {
        let modules = "/super/.git/modules/sub"
        #expect(RepoWatcher.touchesGitMetadata(["\(modules)/refs/heads/main"], gitDirs: [modules]))
        #expect(!RepoWatcher.touchesGitMetadata(["\(modules)/index"], gitDirs: [modules]))
    }

    @Test func plainCheckoutKeepsSubstringFallback() {
        #expect(RepoWatcher.touchesGitMetadata(["/private/tmp/r/.git/refs/heads/main"]))
        #expect(RepoWatcher.touchesGitMetadata(["/private/tmp/r/.git/HEAD.lock"]))
        #expect(!RepoWatcher.touchesGitMetadata(["/private/tmp/r/.git/index"]))
        #expect(RepoWatcher.touchesGitMetadata([]), "unknown paths refresh everything")
    }

    // The watcher needs the git dirs outside the root: a linked worktree's
    // must resolve to the real common-dir locations.
    @Test func linkedWorktreeMetadataDirectoriesResolve() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("gital-watcher-tests-\(UUID().uuidString)")
        let main = base.appendingPathComponent("main")
        let linked = base.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let git = GitExecutor(workingDirectory: main)
        _ = try await git.run(["init", "-b", "main"])
        _ = try await git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--allow-empty", "-m", "base"])
        _ = try await git.run(["worktree", "add", "-b", "wt", linked.path])

        let dirs = try await GitRepository(root: linked).metadataDirectories()
        let realMain = RepoWatcher.realPath(main.path)
        #expect(dirs == ["\(realMain)/.git/worktrees/linked", "\(realMain)/.git"])
    }
}
