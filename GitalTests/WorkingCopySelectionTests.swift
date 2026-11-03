import Foundation
import Testing
@testable import Gital

/// Selections must follow what git did to them: a staged file moves to the
/// Staged list, a committed one leaves the working copy, an amended HEAD is
/// replaced by its new commit.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WorkingCopySelectionTests {
    private func withRepo(_ body: (RepoViewModel, GitExecutor, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gital-wc-selection-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let git = GitExecutor(workingDirectory: root)
        _ = try await git.run(["init", "-b", "main"])
        _ = try await git.run(["config", "user.name", "Gital Tests"])
        _ = try await git.run(["config", "user.email", "tests@example.com"])
        _ = try await git.run(["config", "commit.gpgsign", "false"])
        for name in ["a.txt", "b.txt"] {
            try Data((1...30).map { "\(name) line \($0)\n" }.joined().utf8).write(to: root.appendingPathComponent(name))
        }
        _ = try await git.run(["add", "."])
        _ = try await git.run(["commit", "-m", "base"])

        let model = RepoViewModel(repository: GitRepository(root: root), watchFileSystem: false)
        defer { model.close() }
        try await body(model, git, root)
    }

    /// The selection's didSet starts its own diff load, which supersedes a
    /// direct `loadWorkingDiffs()` call — wait for whichever lands.
    private func waitForDiffs(_ model: RepoViewModel) async throws {
        for _ in 0..<250 where model.workingDiffs.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func append(_ text: String, to name: String, in root: URL) throws {
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent(name))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    // Staging the selected unstaged file left the selection on the unstaged
    // side, where the path no longer exists: the pane fell back to "No
    // changes in the working copy" while the file sat in Staged.
    @Test func stagingTheSelectedFileFollowsItToStaged() async throws {
        try await withRepo { model, git, root in
            try append("more\n", to: "a.txt", in: root)
            try append("more\n", to: "b.txt", in: root)
            await model.refreshStatus()
            model.selectedChange = .init(path: "a.txt", staged: false)
            _ = try await git.run(["add", "a.txt"])
            await model.refreshStatus()
            #expect(model.selectedChange == .init(path: "a.txt", staged: true))
            try await waitForDiffs(model)
            #expect(model.workingDiffs.map(\.path) == ["a.txt"])
        }
    }

    @Test func committingTheSelectedFileClearsTheSelection() async throws {
        try await withRepo { model, git, root in
            try append("more\n", to: "a.txt", in: root)
            try append("more\n", to: "b.txt", in: root)
            _ = try await git.run(["add", "a.txt"])
            await model.refreshStatus()
            model.selectedChange = .init(path: "a.txt", staged: true)
            _ = try await git.run(["commit", "-m", "a"])
            await model.refreshStatus()
            #expect(model.selectedChange == nil)
        }
    }

    // A partially staged file is on both sides; the selection stays put.
    @Test func partiallyStagedSelectionStays() async throws {
        try await withRepo { model, git, root in
            try append("more\n", to: "a.txt", in: root)
            _ = try await git.run(["add", "a.txt"])
            try append("even more\n", to: "a.txt", in: root)
            await model.refreshStatus()
            model.selectedChange = .init(path: "a.txt", staged: false)
            await model.refreshStatus()
            #expect(model.selectedChange == .init(path: "a.txt", staged: false))
        }
    }

    // The staged diff of a single renamed file was fetched with only the new
    // path as pathspec, which breaks the rename pair: it showed as an
    // all-additions new file (and unstaging a hunk dropped the path).
    @Test func selectedStagedRenameDiffsAsRename() async throws {
        try await withRepo { model, git, root in
            _ = try await git.run(["mv", "a.txt", "renamed.txt"])
            try append("more\n", to: "renamed.txt", in: root)
            _ = try await git.run(["add", "renamed.txt"])
            await model.refreshStatus()
            model.selectedChange = .init(path: "renamed.txt", staged: true)
            try await waitForDiffs(model)
            let diff = try #require(model.workingDiffs.first)
            #expect(model.workingDiffs.count == 1)
            #expect(diff.path == "renamed.txt" && diff.oldPath == "a.txt")
            #expect(diff.hunks.flatMap(\.lines).filter { $0.kind == .addition }.map(\.text) == ["more"])
        }
    }

    // Amending while HEAD was selected left History pinned to the replaced
    // commit: no row highlighted, the detail pane showing the old message.
    @Test func amendingTheSelectedHeadSelectsTheNewHead() async throws {
        try await withRepo { model, git, root in
            await model.refreshAll()
            let oldHead = try await git.run(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(model.selectedCommitHash == oldHead)
            try append("more\n", to: "a.txt", in: root)
            _ = try await git.run(["add", "a.txt"])
            await model.refreshStatus()
            model.amend = true
            model.commitMessage = "amended"
            model.commit()
            for _ in 0..<200 where model.isCommitting || model.commitMessage == "amended" {
                try await Task.sleep(for: .milliseconds(20))
            }
            while model.isCommitting { try await Task.sleep(for: .milliseconds(20)) }
            let newHead = try await git.run(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(newHead != oldHead)
            #expect(model.selectedCommitHash == newHead)
        }
    }

    @Test func resettingAwayFromTheSelectedHeadSelectsTheNewHead() async throws {
        try await withRepo { model, git, root in
            try append("more\n", to: "a.txt", in: root)
            _ = try await git.run(["commit", "-am", "second"])
            await model.refreshAll()
            let base = try await git.run(["rev-parse", "HEAD~1"]).trimmingCharacters(in: .whitespacesAndNewlines)
            model.performReset(toHash: base, mode: .mixed)
            for _ in 0..<250 where model.selectedCommitHash != base {
                try await Task.sleep(for: .milliseconds(20))
            }
            while model.isSyncing { try await Task.sleep(for: .milliseconds(20)) }
            #expect(model.selectedCommitHash == base)
        }
    }
}
