import Foundation
import Testing
@testable import Gital

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CommitEditSessionTests {

    private func commit(_ hash: String, subject: String = "subject") -> RebaseCommit {
        RebaseCommit(
            hash: hash,
            subject: subject,
            message: subject,
            author: "A",
            identity: "1700000000,a@b.c,\(subject)",
            isMerge: false
        )
    }

    private func session(
        targetHash: String = String(repeating: "a", count: 40),
        message: String = "Fix crash\n\nLong body",
        phase: GitRepository.CommitEditSession.Phase = .editing,
        stashCommitHash: String? = nil
    ) -> GitRepository.CommitEditSession {
        GitRepository.CommitEditSession(
            targetHash: targetHash,
            originalMessage: message,
            authorName: "Alice Author",
            authorEmail: "alice@example.com",
            authorDate: "1700000000 +0900",
            baseHash: String(repeating: "b", count: 40),
            headBeforeRebase: String(repeating: "f", count: 40),
            phase: phase,
            stashCommitHash: stashCommitHash
        )
    }

    // MARK: - Todo generation

    @Test func headTargetProducesASingleEditLine() {
        let todo = GitRepository.editSessionTodoScript(
            target: commit("aaa", subject: "only"),
            descendantsNewestFirst: []
        )
        #expect(todo == "edit aaa only\n")
    }

    @Test func descendantsArePickedOldestFirstAfterTheEditStop() {
        // Descendants arrive newest first (display order); the todo runs top
        // to bottom, so they must be emitted oldest first after the edit.
        let todo = GitRepository.editSessionTodoScript(
            target: commit("aaa", subject: "target"),
            descendantsNewestFirst: [commit("ccc", subject: "newest"), commit("bbb", subject: "middle")]
        )
        #expect(todo == "edit aaa target\npick bbb middle\npick ccc newest\n")
    }

    // MARK: - Prep derivation

    @Test func editPrepSplitsTargetFromDescendants() throws {
        let prep = GitRepository.InteractiveRebasePrep(
            commits: [commit("ccc"), commit("bbb"), commit("aaa")],
            baseHash: "parent"
        )
        let edit = try GitRepository.editPrep(from: prep, targetHash: "aaa")
        #expect(edit.target.hash == "aaa")
        #expect(edit.descendantsNewestFirst.map(\.hash) == ["ccc", "bbb"])
        #expect(edit.baseHash == "parent")
        #expect(edit.expectedHead == "ccc")
    }

    @Test func editPrepOfHeadCommitHasNoDescendants() throws {
        let prep = GitRepository.InteractiveRebasePrep(commits: [commit("aaa")], baseHash: "parent")
        let edit = try GitRepository.editPrep(from: prep, targetHash: "aaa")
        #expect(edit.descendantsNewestFirst.isEmpty)
        #expect(edit.expectedHead == "aaa")
    }

    // `reset --soft HEAD^` has no parent to reset onto at the root.
    @Test func editPrepRejectsRootTargets() {
        let prep = GitRepository.InteractiveRebasePrep(commits: [commit("aaa")], baseHash: nil)
        #expect(throws: GitError.self) {
            _ = try GitRepository.editPrep(from: prep, targetHash: "aaa")
        }
    }

    // A span whose oldest commit is not the requested target would edit the
    // wrong commit — refuse instead.
    @Test func editPrepRejectsSpanTargetMismatch() {
        let prep = GitRepository.InteractiveRebasePrep(
            commits: [commit("bbb"), commit("aaa")],
            baseHash: "parent"
        )
        #expect(throws: GitError.self) {
            _ = try GitRepository.editPrep(from: prep, targetHash: "bbb")
        }
        #expect(throws: GitError.self) {
            _ = try GitRepository.editPrep(
                from: GitRepository.InteractiveRebasePrep(commits: [], baseHash: "parent"),
                targetHash: "aaa"
            )
        }
    }

    // MARK: - Pushed probe

    @Test func pushedProbeComparesAgainstTheUpstream() {
        #expect(GitRepository.pushedProbeArguments("abc123")
            == ["merge-base", "--is-ancestor", "abc123", "@{u}"])
    }

    // MARK: - Save commit argv

    @Test func saveCommitCarriesOriginalAuthorAndDate() {
        let args = GitRepository.editSaveCommitArguments(message: "New message", session: session(), amend: false)
        #expect(args.first == "commit")
        #expect(args.contains("--author=Alice Author <alice@example.com>"))
        #expect(args.contains("--date=1700000000 +0900"))
        // The user may have removed every change from the commit; recording
        // it empty must stay legal.
        #expect(args.contains("--allow-empty"))
        #expect(!args.contains("--amend"))
        #expect(Array(args.suffix(2)) == ["-m", "New message"])
    }

    // The retry path: a previous save recorded the commit and failed later,
    // so saving again must amend it instead of stacking a second commit.
    @Test func retriedSaveAmendsInsteadOfStackingACommit() {
        let args = GitRepository.editSaveCommitArguments(message: "New message", session: session(), amend: true)
        #expect(args.contains("--amend"))
        #expect(args.contains("--author=Alice Author <alice@example.com>"))
        #expect(args.contains("--date=1700000000 +0900"))
        #expect(Array(args.suffix(2)) == ["-m", "New message"])
    }

    // MARK: - State file encode/decode

    @Test func sessionStateRoundTrips() throws {
        let original = session(phase: .continuing, stashCommitHash: String(repeating: "d", count: 40))
        let decoded = try GitRepository.decodeEditSession(GitRepository.encodeEditSession(original))
        #expect(decoded == original)
    }

    @Test func sessionStateRoundTripsWithoutAStash() throws {
        let original = session(phase: .editing, stashCommitHash: nil)
        let decoded = try GitRepository.decodeEditSession(GitRepository.encodeEditSession(original))
        #expect(decoded == original)
        #expect(decoded.stashCommitHash == nil)
    }

    @Test func decodingGarbageThrows() {
        #expect(throws: (any Error).self) {
            _ = try GitRepository.decodeEditSession(Data("not json".utf8))
        }
        // A future phase value must fail decoding (the caller treats that as
        // "no session" and cleans the file up) rather than misclassify.
        #expect(throws: (any Error).self) {
            _ = try GitRepository.decodeEditSession(Data("""
            {"targetHash":"a","originalMessage":"m","authorName":"n","authorEmail":"e",
             "authorDate":"1 +0000","baseHash":"b","headBeforeRebase":"h","phase":"splitting"}
            """.utf8))
        }
    }

    @Test func subjectIsTheMessagesFirstLine() {
        #expect(session(message: "Fix crash\n\nLong body").subject == "Fix crash")
        #expect(session(message: "One liner").subject == "One liner")
        #expect(session(message: "").subject == "")
    }

    @Test func shortTargetHashIsSevenCharacters() {
        #expect(session(targetHash: String(repeating: "a", count: 40)).shortTargetHash == "aaaaaaa")
    }
}
