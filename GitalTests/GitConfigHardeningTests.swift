import Foundation
import Testing
@testable import Gital

/// The parsers expect git's default output shapes; a user's diff/log config
/// must not be able to change them. Each case sets one such config in a
/// throwaway repo and checks the parsed result against git's default form.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct GitConfigHardeningTests {
    private func withRepo(
        config: [(String, String)],
        _ body: (GitRepository, GitExecutor, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gital-config-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let git = GitExecutor(workingDirectory: root)
        _ = try await git.run(["init", "-b", "main"])
        _ = try await git.run(["config", "user.name", "Gital Tests"])
        _ = try await git.run(["config", "user.email", "tests@example.com"])
        _ = try await git.run(["config", "commit.gpgsign", "false"])
        try Data("\n\nfoo\nold\nbar\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        _ = try await git.run(["add", "."])
        _ = try await git.run(["commit", "-m", "base"])
        _ = try await git.run(["tag", "v1"])
        for (key, value) in config {
            _ = try await git.run(["config", key, value])
        }
        try await body(GitRepository(root: root), git, root)
    }

    private func modify(_ root: URL) throws {
        try Data("\n\nfoo\nnew\nbar\n".utf8).write(to: root.appendingPathComponent("file.txt"))
    }

    // diff.external replaced the patch with the external tool's output (no
    // `diff --git` header), so the Changes pane parsed to nothing.
    @Test func externalDiffToolIsBypassed() async throws {
        try await withRepo(config: [("diff.external", "/bin/echo")]) { repo, _, root in
            try modify(root)
            let diffs = try await repo.diffWorking(staged: false)
            #expect(diffs.map(\.path) == ["file.txt"])
            #expect(diffs.first?.hunks.isEmpty == false)
        }
    }

    // color.diff=always beats the executor's color.ui=false and prefixes
    // every header with an escape sequence the parser can't see past.
    @Test func forcedDiffColorIsBypassed() async throws {
        try await withRepo(config: [("color.diff", "always")]) { repo, git, root in
            try modify(root)
            #expect(try await repo.diffWorking(staged: false).map(\.path) == ["file.txt"])
            _ = try await git.run(["stash", "push", "-m", "s"])
            let stash = try #require(try await repo.stashes().first)
            #expect(try await repo.stashDiff(stash).map(\.path) == ["file.txt"])
        }
    }

    // mnemonicPrefix writes `i/` / `w/` instead of `a/` / `b/`: the file
    // read as a rename from "i/file.txt" to "w/file.txt".
    @Test func mnemonicPrefixesAreNormalized() async throws {
        try await withRepo(config: [("diff.mnemonicPrefix", "true")]) { repo, git, root in
            try modify(root)
            let unstaged = try #require(try await repo.diffWorking(staged: false).first)
            #expect(unstaged.path == "file.txt" && unstaged.oldPath == nil)
            _ = try await git.run(["add", "."])
            let staged = try #require(try await repo.diffWorking(staged: true).first)
            #expect(staged.path == "file.txt" && staged.oldPath == nil)
        }
    }

    // noprefix: a real top-level directory named "a" lost its first
    // component to prefix stripping.
    @Test func noPrefixIsNormalized() async throws {
        try await withRepo(config: [("diff.noprefix", "true")]) { repo, git, root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
            try Data("x\n".utf8).write(to: root.appendingPathComponent("a/x.txt"))
            _ = try await git.run(["add", "."])
            _ = try await git.run(["commit", "-m", "add a/x.txt"])
            let head = try await git.run(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let diff = try #require(try await repo.diffCommit(head).first)
            #expect(diff.path == "a/x.txt")
        }
    }

    // suppressBlankEmpty prints empty context lines as "" instead of " ",
    // which the parser skipped — every later line was misnumbered.
    @Test func blankContextLinesKeepTheirNumbers() async throws {
        try await withRepo(config: [("diff.suppressBlankEmpty", "true")]) { repo, _, root in
            try modify(root)
            let diff = try #require(try await repo.diffWorking(staged: false).first)
            let lines = diff.hunks.flatMap(\.lines)
            let foo = try #require(lines.first { $0.text == "foo" })
            #expect(foo.newNumber == 3, "context line after two blank lines is line 3")
            #expect(lines.filter { $0.kind == .context && $0.text.isEmpty }.count == 2)
        }
    }

    // log.decorate=full turned chips into "refs/heads/main" / "refs/tags/v1".
    @Test func fullDecorationsAreShortened() async throws {
        try await withRepo(config: [("log.decorate", "full")]) { repo, _, _ in
            let commit = try #require(try await repo.log().first)
            #expect(commit.refs.contains(GitRef(kind: .head, name: "main")))
            #expect(commit.refs.contains(GitRef(kind: .tag, name: "v1")))
            let detail = try #require(try await repo.commitDetail(commit.hash))
            #expect(detail.refs.contains(GitRef(kind: .tag, name: "v1")))
        }
    }

    // A numstat path containing a TAB was cut at the TAB.
    @Test func numstatPathWithTabSurvives() {
        let numstat = Data("1\t1\ttab\tname.txt\u{0}".utf8)
        let nameStatus = Data("M\u{0}tab\tname.txt\u{0}".utf8)
        let stats = GitRepository.parseCommitStats(numstat: numstat, nameStatus: nameStatus)
        #expect(stats.map(\.path) == ["tab\tname.txt"])
        #expect(stats.first?.additions == 1)
    }

    // Remote names may contain "/" (`git remote add team/up …`); their
    // branches must not read as local branches.
    @Test func remoteNameWithSlashClassifiesAsRemote() {
        let refs = GitRepository.parseRefs("team/up/main\u{1f}feature/x", remotes: ["team/up", "origin"])
        #expect(refs == [GitRef(kind: .remoteBranch, name: "team/up/main"), GitRef(kind: .branch, name: "feature/x")])
    }
}
