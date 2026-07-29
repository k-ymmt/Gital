import Foundation
import Testing
@testable import Gital

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct InteractiveRebaseTests {

    private func commit(
        _ hash: String,
        subject: String = "subject",
        message: String? = nil,
        identity: String? = nil
    ) -> RebaseCommit {
        RebaseCommit(
            hash: hash,
            subject: subject,
            message: message ?? subject,
            author: "A",
            identity: identity ?? "1700000000,a@b.c,\(subject)",
            isMerge: false
        )
    }

    /// Decodes the base64 payload of a guarded `exec … | git commit --amend`
    /// line back into the message it would install.
    private func execMessage(_ line: String) -> String? {
        guard line.hasPrefix("exec "), let range = line.range(of: "printf %s ") else { return nil }
        let payload = line[range.upperBound...].prefix { $0 != " " }
        guard let data = Data(base64Encoded: String(payload)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - parseFirstParent

    @Test func firstParentOfNormalCommit() {
        #expect(GitRepository.parseFirstParent("aaa bbb\n") == "bbb")
    }

    @Test func firstParentOfMergeCommitIsTheFirstListed() {
        #expect(GitRepository.parseFirstParent("aaa bbb ccc\n") == "bbb")
    }

    @Test func rootCommitHasNoParent() {
        #expect(GitRepository.parseFirstParent("aaa\n") == nil)
        #expect(GitRepository.parseFirstParent("") == nil)
    }

    // MARK: - parseRebaseCommits

    private let hashA = String(repeating: "a", count: 40)
    private let hashB = String(repeating: "b", count: 40)
    private let hashC = String(repeating: "c", count: 40)

    /// One `log -z --format=%H%x00%P%x00%an%x00%at,%ae,%s%x00%s%x00%B` record.
    private func record(
        hash: String, parents: String, author: String = "Alice",
        identity: String = "1,a@b,s", subject: String, body: String
    ) -> String {
        [hash, parents, author, identity, subject, body].joined(separator: "\u{0}") + "\u{0}"
    }

    @Test func parsesLogRecords() throws {
        let output = record(hash: hashA, parents: hashB, subject: "Fix crash", body: "Fix crash\n\nLong body\nwith two lines\n")
            + record(hash: hashB, parents: "\(hashC) \(hashA)", author: "Bob", subject: "Merge branch", body: "Merge branch\n")
            + record(hash: hashC, parents: "", author: "Carol", subject: "Root", body: "Root\n")
        let commits = try GitRepository.parseRebaseCommits(output)
        #expect(commits.count == 3)
        #expect(commits[0].hash == hashA)
        #expect(commits[0].subject == "Fix crash")
        #expect(commits[0].message == "Fix crash\n\nLong body\nwith two lines")
        #expect(commits[0].author == "Alice")
        #expect(commits[0].identity == "1,a@b,s")
        #expect(!commits[0].isMerge)
        #expect(commits[1].isMerge)
        #expect(!commits[2].isMerge)
    }

    // Regression: subjects/messages can contain any byte except NUL —
    // including the old record separator \u{1e}. A commit must never be
    // silently dropped (the rebase would then delete it).
    @Test func recordSeparatorBytesInContentDoNotShiftRecords() throws {
        let evil = "evil\u{1e}trick"
        let output = record(hash: hashA, parents: hashB, subject: evil, body: "\(evil)\n\nbody\u{1e}tail\n")
            + record(hash: hashB, parents: "", subject: "normal", body: "normal\n")
        let commits = try GitRepository.parseRebaseCommits(output)
        #expect(commits.count == 2)
        #expect(commits[0].subject == evil)
        #expect(commits[0].message == "\(evil)\n\nbody\u{1e}tail")
    }

    @Test func malformedOutputThrowsInsteadOfDroppingCommits() {
        // Truncated record (missing fields).
        #expect(throws: GitError.self) {
            _ = try GitRepository.parseRebaseCommits("\(hashA)\u{0}parents\u{0}")
        }
        // Missing the final record terminator.
        #expect(throws: GitError.self) {
            _ = try GitRepository.parseRebaseCommits(
                [hashA, "", "A", "1,a,s", "s", "s"].joined(separator: "\u{0}")
            )
        }
        // Field where a hash should be.
        #expect(throws: GitError.self) {
            _ = try GitRepository.parseRebaseCommits(
                record(hash: "not-a-hash", parents: "", subject: "s", body: "s")
            )
        }
    }

    @Test func emptyOutputParsesToNoCommits() throws {
        #expect(try GitRepository.parseRebaseCommits("").isEmpty)
    }

    // MARK: - Worktree cleanliness

    @Test func untrackedAndIgnoredFilesDoNotBlockRebase() {
        #expect(GitRepository.isCleanForRebase(""))
        #expect(GitRepository.isCleanForRebase("?? new.txt\n!! ignored.log\n"))
        #expect(!GitRepository.isCleanForRebase(" M edited.txt\n"))
        #expect(!GitRepository.isCleanForRebase("M  staged.txt\n?? new.txt\n"))
        #expect(!GitRepository.isCleanForRebase("R  a.txt -> b.txt\n"))
    }

    // MARK: - Todo generation

    @Test func pickOnlyPlanEmitsPicks() throws {
        let steps = [
            RebaseStep(commit: commit("aaa", subject: "first"), message: "first"),
            RebaseStep(commit: commit("bbb", subject: "second"), message: "second"),
        ]
        let todo = try GitRepository.rebaseTodoScript(stepsOldestFirst: steps, requireSurvivor: false)
        #expect(todo == "pick aaa first\npick bbb second\n")
    }

    @Test func dropEmitsExplicitDropLine() throws {
        let steps = [
            RebaseStep(commit: commit("aaa"), message: "subject"),
            RebaseStep(commit: commit("bbb"), action: .drop, message: "subject"),
        ]
        let todo = try GitRepository.rebaseTodoScript(stepsOldestFirst: steps, requireSurvivor: false)
        #expect(todo.contains("drop bbb"))
    }

    @Test func rewordAppendsGuardedAmendExec() throws {
        let steps = [
            RebaseStep(commit: commit("aaa"), action: .reword, message: "New title\n\nNew body"),
            RebaseStep(commit: commit("bbb", subject: "next"), message: "next"),
        ]
        let lines = try GitRepository.rebaseTodoScript(stepsOldestFirst: steps, requireSurvivor: false)
            .split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0] == "pick aaa subject")
        #expect(execMessage(lines[1]) == "New title\n\nNew body")
        // The amend must be guarded by the target's identity so a skipped
        // pick can never leak the rewrite onto another commit.
        #expect(lines[1].contains("if test \"$(git log -1 --format=%at,%ae,%s 2>/dev/null)\" = '1700000000,a@b.c,subject'"))
        #expect(lines[2] == "pick bbb next")
    }

    @Test func squashEmitsGuardedFoldAndCombinedMessageExec() throws {
        let steps = [
            RebaseStep(commit: commit("aaa", message: "Base message"), message: "Base message"),
            RebaseStep(commit: commit("bbb", subject: "folded", message: "Folded in"), action: .squash, message: "Folded in"),
        ]
        let lines = try GitRepository.rebaseTodoScript(stepsOldestFirst: steps, requireSurvivor: false)
            .split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(lines[0] == "pick aaa subject")
        // The follower is picked, then folded by a guarded exec — never a
        // native fixup, which folds into whatever HEAD is after a skip.
        #expect(lines[1] == "pick bbb folded")
        #expect(lines[2].contains("git reset --soft HEAD^ && git commit --amend --no-edit"))
        #expect(lines[2].contains("--skip=1"))
        #expect(lines[2].contains("'1700000000,a@b.c,folded'"))
        #expect(lines[2].contains("'1700000000,a@b.c,subject'"))
        #expect(execMessage(lines[3]) == "Base message\n\nFolded in")
    }

    @Test func fixupKeepsBaseMessageWithoutAmendExec() throws {
        let steps = [
            RebaseStep(commit: commit("aaa"), message: "subject"),
            RebaseStep(commit: commit("bbb"), action: .fixup, message: "ignored"),
        ]
        let lines = try GitRepository.rebaseTodoScript(stepsOldestFirst: steps, requireSurvivor: false)
            .split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0] == "pick aaa subject")
        #expect(lines[1] == "pick bbb subject")
        #expect(lines[2].contains("reset --soft HEAD^"))
        #expect(!lines.contains { execMessage($0) != nil })
    }

    // The amend exec must land after the group's followers, even when a drop
    // line sits between them.
    @Test func amendExecComesAfterTheWholeGroup() throws {
        let steps = [
            RebaseStep(commit: commit("aaa"), action: .reword, message: "Rewritten"),
            RebaseStep(commit: commit("bbb"), action: .drop, message: "x"),
            RebaseStep(commit: commit("ccc", subject: "fix"), action: .fixup, message: "x"),
        ]
        let lines = try GitRepository.rebaseTodoScript(stepsOldestFirst: steps, requireSurvivor: false)
            .split(separator: "\n").map(String.init)
        #expect(lines[0] == "pick aaa subject")
        #expect(lines[1] == "drop bbb")
        #expect(lines[2] == "pick ccc fix")
        #expect(lines[3].contains("reset --soft HEAD^"))
        #expect(execMessage(lines[4]) == "Rewritten")
    }

    @Test func squashWithoutBaseThrows() {
        let steps = [
            RebaseStep(commit: commit("aaa"), action: .squash, message: "x"),
        ]
        #expect(throws: GitError.self) {
            try GitRepository.rebaseTodoScript(stepsOldestFirst: steps, requireSurvivor: false)
        }
    }

    @Test func fixupAfterOnlyDropsThrows() {
        let steps = [
            RebaseStep(commit: commit("aaa"), action: .drop, message: "x"),
            RebaseStep(commit: commit("bbb"), action: .fixup, message: "x"),
        ]
        #expect(throws: GitError.self) {
            try GitRepository.rebaseTodoScript(stepsOldestFirst: steps, requireSurvivor: false)
        }
    }

    @Test func emptyRewordMessageThrows() {
        let steps = [
            RebaseStep(commit: commit("aaa"), action: .reword, message: "   \n "),
        ]
        #expect(throws: GitError.self) {
            try GitRepository.rebaseTodoScript(stepsOldestFirst: steps, requireSurvivor: false)
        }
    }

    @Test func consecutiveSquashesAccumulateInOrder() throws {
        let steps = [
            RebaseStep(commit: commit("aaa", message: "One"), message: "One"),
            RebaseStep(commit: commit("bbb", message: "Two"), action: .squash, message: "Two"),
            RebaseStep(commit: commit("ccc", message: "Three"), action: .squash, message: "Three"),
        ]
        let lines = try GitRepository.rebaseTodoScript(stepsOldestFirst: steps, requireSurvivor: false)
            .split(separator: "\n").map(String.init)
        // One amend exec per resulting commit — the intermediate combination
        // is superseded, not emitted.
        let amends = lines.compactMap { execMessage($0) }
        #expect(amends == ["One\n\nTwo\n\nThree"])
    }

    // With --root there is no base to fall back to; a plan that drops every
    // commit would leave the branch on git's empty sentinel commit.
    @Test func droppingEverythingRequiresASurvivorForRootSpans() throws {
        let steps = [
            RebaseStep(commit: commit("aaa"), action: .drop, message: "x"),
            RebaseStep(commit: commit("bbb"), action: .drop, message: "x"),
        ]
        #expect(throws: GitError.self) {
            try GitRepository.rebaseTodoScript(stepsOldestFirst: steps, requireSurvivor: true)
        }
        // With a real base the same plan is a legitimate "delete the span".
        let todo = try GitRepository.rebaseTodoScript(stepsOldestFirst: steps, requireSurvivor: false)
        #expect(todo == "drop aaa\ndrop bbb\n")
    }

    // The message travels as one argv word; past ARG_MAX the exec line makes
    // sh fail mid-rebase, so oversized drafts must be rejected up front.
    @Test func oversizedMessageThrows() {
        let steps = [
            RebaseStep(
                commit: commit("aaa"),
                action: .reword,
                message: String(repeating: "x", count: GitRepository.maxAmendMessageBytes + 1)
            ),
        ]
        #expect(throws: GitError.self) {
            try GitRepository.rebaseTodoScript(stepsOldestFirst: steps, requireSurvivor: false)
        }
    }

    // MARK: - Exec lines / quoting

    @Test func amendExecLineRoundTripsArbitraryMessages() {
        let message = "Title with 'quotes' & $vars\n\nBody % \\n literal\nLine 3"
        let line = GitRepository.amendExecLine(base: commit("aaa"), message: message)
        #expect(execMessage(line) == message)
        #expect(line.contains("git commit --amend"))
        #expect(!line.contains("\n"))
    }

    @Test func identityGuardsAreShellQuoted() {
        let hostile = commit("aaa", identity: "1,a@b,it's a 'subject'")
        let line = GitRepository.amendExecLine(base: hostile, message: "m")
        #expect(line.contains("'1,a@b,it'\\''s a '\\''subject'\\'''"))
        // The guard must fail soft (echo, not amend) — never amend without it.
        #expect(line.contains("else echo"))
        #expect(line.hasPrefix("exec if test "))
    }

    @Test func shellQuoteHandlesSpacesAndQuotes() {
        #expect(GitRepository.shellQuote("/tmp/plain") == "'/tmp/plain'")
        #expect(GitRepository.shellQuote("/tmp/with space") == "'/tmp/with space'")
        #expect(GitRepository.shellQuote("/tmp/it's") == "'/tmp/it'\\''s'")
    }

    // MARK: - Continue/skip config pins

    @Test func rebaseContinuationPinsTodoParsingConfig() {
        let args = GitRepository.operationArguments(.rebase)
        #expect(args.contains("core.commentChar=#"))
        #expect(args.contains("rebase.rescheduleFailedExec=true"))
        #expect(args.contains("core.editor=true"))
        // Other operations keep only the editor pin.
        #expect(GitRepository.operationArguments(.merge) == ["-c", "core.editor=true"])
    }
}
