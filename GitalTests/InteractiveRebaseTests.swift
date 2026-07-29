import Foundation
import Testing
@testable import Gital

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct InteractiveRebaseTests {

    private func commit(_ hash: String, subject: String = "subject", message: String? = nil) -> RebaseCommit {
        RebaseCommit(hash: hash, subject: subject, message: message ?? subject, author: "A", isMerge: false)
    }

    /// Decodes the base64 payload of an `exec … | git commit --amend` line
    /// back into the message it would install.
    private func execMessage(_ line: String) -> String? {
        let tokens = line.split(separator: " ")
        guard tokens.count >= 4, tokens[0] == "exec", tokens[1] == "printf" else { return nil }
        guard let data = Data(base64Encoded: String(tokens[3])) else { return nil }
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

    @Test func parsesLogRecords() {
        let output = [
            "aaa\u{0}bbb\u{0}Alice\u{0}Fix crash\u{0}Fix crash\n\nLong body\nwith two lines\n",
            "bbb\u{0}ccc ddd\u{0}Bob\u{0}Merge branch\u{0}Merge branch\n",
            "ccc\u{0}\u{0}Carol\u{0}Root\u{0}Root\n",
        ].joined(separator: "\u{1e}") + "\u{1e}"
        let commits = GitRepository.parseRebaseCommits(output)
        #expect(commits.count == 3)
        #expect(commits[0].hash == "aaa")
        #expect(commits[0].subject == "Fix crash")
        #expect(commits[0].message == "Fix crash\n\nLong body\nwith two lines")
        #expect(commits[0].author == "Alice")
        #expect(!commits[0].isMerge)
        #expect(commits[1].isMerge)
        #expect(!commits[2].isMerge)
    }

    @Test func skipsMalformedRecords() {
        #expect(GitRepository.parseRebaseCommits("").isEmpty)
        #expect(GitRepository.parseRebaseCommits("\n\u{1e}").isEmpty)
        #expect(GitRepository.parseRebaseCommits("only\u{0}two").isEmpty)
    }

    // MARK: - Todo generation

    @Test func pickOnlyPlanEmitsPicks() throws {
        let steps = [
            RebaseStep(commit: commit("aaa", subject: "first"), message: "first"),
            RebaseStep(commit: commit("bbb", subject: "second"), message: "second"),
        ]
        let todo = try GitRepository.rebaseTodoScript(stepsOldestFirst: steps)
        #expect(todo == "pick aaa first\npick bbb second\n")
    }

    @Test func dropEmitsExplicitDropLine() throws {
        let steps = [
            RebaseStep(commit: commit("aaa"), message: "subject"),
            RebaseStep(commit: commit("bbb"), action: .drop, message: "subject"),
        ]
        let todo = try GitRepository.rebaseTodoScript(stepsOldestFirst: steps)
        #expect(todo.contains("drop bbb"))
    }

    @Test func rewordAppendsAmendExec() throws {
        let steps = [
            RebaseStep(commit: commit("aaa"), action: .reword, message: "New title\n\nNew body"),
            RebaseStep(commit: commit("bbb", subject: "next"), message: "next"),
        ]
        let lines = try GitRepository.rebaseTodoScript(stepsOldestFirst: steps)
            .split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0] == "pick aaa subject")
        #expect(execMessage(lines[1]) == "New title\n\nNew body")
        #expect(lines[2] == "pick bbb next")
    }

    @Test func squashEmitsFixupAndCombinedMessageExec() throws {
        let steps = [
            RebaseStep(commit: commit("aaa", message: "Base message"), message: "Base message"),
            RebaseStep(commit: commit("bbb", message: "Folded in"), action: .squash, message: "Folded in"),
        ]
        let lines = try GitRepository.rebaseTodoScript(stepsOldestFirst: steps)
            .split(separator: "\n").map(String.init)
        #expect(lines[0] == "pick aaa subject")
        #expect(lines[1] == "fixup bbb")
        #expect(execMessage(lines[2]) == "Base message\n\nFolded in")
    }

    @Test func fixupKeepsBaseMessageWithoutExec() throws {
        let steps = [
            RebaseStep(commit: commit("aaa"), message: "subject"),
            RebaseStep(commit: commit("bbb"), action: .fixup, message: "ignored"),
        ]
        let todo = try GitRepository.rebaseTodoScript(stepsOldestFirst: steps)
        #expect(todo == "pick aaa subject\nfixup bbb\n")
    }

    // The exec must land after the group's last follower, even when a drop
    // line sits between them — `drop` creates no commit, so the amend still
    // targets the group base.
    @Test func execComesAfterTheWholeGroup() throws {
        let steps = [
            RebaseStep(commit: commit("aaa"), action: .reword, message: "Rewritten"),
            RebaseStep(commit: commit("bbb"), action: .drop, message: "x"),
            RebaseStep(commit: commit("ccc"), action: .fixup, message: "x"),
        ]
        let lines = try GitRepository.rebaseTodoScript(stepsOldestFirst: steps)
            .split(separator: "\n").map(String.init)
        #expect(lines[0] == "pick aaa subject")
        #expect(lines[1] == "drop bbb")
        #expect(lines[2] == "fixup ccc")
        #expect(execMessage(lines[3]) == "Rewritten")
    }

    @Test func squashWithoutBaseThrows() {
        let steps = [
            RebaseStep(commit: commit("aaa"), action: .squash, message: "x"),
        ]
        #expect(throws: GitError.self) {
            try GitRepository.rebaseTodoScript(stepsOldestFirst: steps)
        }
    }

    @Test func fixupAfterOnlyDropsThrows() {
        let steps = [
            RebaseStep(commit: commit("aaa"), action: .drop, message: "x"),
            RebaseStep(commit: commit("bbb"), action: .fixup, message: "x"),
        ]
        #expect(throws: GitError.self) {
            try GitRepository.rebaseTodoScript(stepsOldestFirst: steps)
        }
    }

    @Test func emptyRewordMessageThrows() {
        let steps = [
            RebaseStep(commit: commit("aaa"), action: .reword, message: "   \n "),
        ]
        #expect(throws: GitError.self) {
            try GitRepository.rebaseTodoScript(stepsOldestFirst: steps)
        }
    }

    @Test func consecutiveSquashesAccumulateInOrder() throws {
        let steps = [
            RebaseStep(commit: commit("aaa", message: "One"), message: "One"),
            RebaseStep(commit: commit("bbb", message: "Two"), action: .squash, message: "Two"),
            RebaseStep(commit: commit("ccc", message: "Three"), action: .squash, message: "Three"),
        ]
        let lines = try GitRepository.rebaseTodoScript(stepsOldestFirst: steps)
            .split(separator: "\n").map(String.init)
        // One exec per resulting commit — the intermediate combination is
        // superseded, not emitted.
        #expect(lines.filter { $0.hasPrefix("exec ") }.count == 1)
        #expect(execMessage(lines[3]) == "One\n\nTwo\n\nThree")
    }

    // MARK: - Exec line / quoting

    @Test func amendExecLineRoundTripsArbitraryMessages() {
        let message = "Title with 'quotes' & $vars\n\nBody % \\n literal\nLine 3"
        let line = GitRepository.amendExecLine(message: message)
        #expect(execMessage(line) == message)
        #expect(line.contains("git commit --amend"))
        #expect(!line.contains("\n"))
    }

    @Test func shellQuoteHandlesSpacesAndQuotes() {
        #expect(GitRepository.shellQuote("/tmp/plain") == "'/tmp/plain'")
        #expect(GitRepository.shellQuote("/tmp/with space") == "'/tmp/with space'")
        #expect(GitRepository.shellQuote("/tmp/it's") == "'/tmp/it'\\''s'")
    }
}
