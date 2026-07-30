import Testing
@testable import Gital

@MainActor
@Suite struct CommitMessageGeneratorTests {
    // MARK: - extractMessage

    @Test func plainReplyIsTrimmedAndKept() {
        let raw = "\n  Add commit message generation\n\nWire codex into the composer.\n"
        #expect(CommitMessageGenerator.extractMessage(raw)
            == "Add commit message generation\n\nWire codex into the composer.")
    }

    @Test func fullyFencedReplyIsUnwrapped() {
        let raw = "```\nAdd feature\n\nBody line.\n```"
        #expect(CommitMessageGenerator.extractMessage(raw) == "Add feature\n\nBody line.")
    }

    @Test func fenceWithLanguageTagIsUnwrapped() {
        let raw = "```text\nAdd feature\n```"
        #expect(CommitMessageGenerator.extractMessage(raw) == "Add feature")
    }

    @Test func tildeFenceIsUnwrapped() {
        let raw = "~~~\nAdd feature\n~~~"
        #expect(CommitMessageGenerator.extractMessage(raw) == "Add feature")
    }

    @Test func interiorFenceIsNotUnwrapped() {
        // A fence in the middle of prose is content, not wrapping.
        let raw = "Add feature\n\n```\ncode sample\n```\n\nMore body."
        #expect(CommitMessageGenerator.extractMessage(raw) == raw)
    }

    @Test func singleLineQuotesAreStripped() {
        #expect(CommitMessageGenerator.extractMessage("\"Add feature\"") == "Add feature")
        #expect(CommitMessageGenerator.extractMessage("“Add feature”") == "Add feature")
        #expect(CommitMessageGenerator.extractMessage("`Add feature`") == "Add feature")
    }

    @Test func ambiguousQuoteEndsAreKept() {
        // Starts and ends with a backtick without being wrapped in them —
        // stripping would corrupt the subject.
        let raw = "`GitExecutor` now serializes `runData`"
        #expect(CommitMessageGenerator.extractMessage(raw) == raw)
        let apostrophes = "'strict' mode implies 'safe'"
        #expect(CommitMessageGenerator.extractMessage(apostrophes) == apostrophes)
    }

    @Test func multiLineQuotesAreKept() {
        // Quotes spanning lines could be legitimate content; only a fully
        // quoted single line is unwrapped.
        let raw = "\"Add feature\nwith a body\""
        #expect(CommitMessageGenerator.extractMessage(raw) == raw)
    }

    @Test func bareQuotePairIsNotSwallowedIntoEmpty() {
        // `""` is count == 2; the guard requires content between the quotes.
        #expect(CommitMessageGenerator.extractMessage("\"\"") == "\"\"")
    }

    @Test func emptyFenceYieldsEmpty() {
        #expect(CommitMessageGenerator.extractMessage("```\n```").isEmpty)
        #expect(CommitMessageGenerator.extractMessage("   \n  ").isEmpty)
    }

    // MARK: - truncate

    @Test func shortDiffIsNotTruncated() {
        let (text, truncated) = CommitMessageGenerator.truncate("short diff", limit: 100)
        #expect(text == "short diff")
        #expect(!truncated)
    }

    @Test func longDiffIsCappedAtLimit() {
        let diff = String(repeating: "x", count: 150)
        let (text, truncated) = CommitMessageGenerator.truncate(diff, limit: 100)
        #expect(text.count == 100)
        #expect(truncated)
    }

    @Test func multibyteDiffWithinCharacterLimitIsNotTruncated() {
        // 150 UTF-8 bytes but only 50 Characters — the byte-count fast path
        // must not misreport this as truncated.
        let diff = String(repeating: "あ", count: 50)
        let (text, truncated) = CommitMessageGenerator.truncate(diff, limit: 100)
        #expect(text == diff)
        #expect(!truncated)
    }

    // MARK: - prompt

    @Test func promptCarriesRulesAndDiff() {
        let prompt = CommitMessageGenerator.prompt(diff: "+added line", amend: false, currentMessage: nil)
        #expect(prompt.contains("ONLY the commit message text"))
        #expect(prompt.contains("+added line"))
        #expect(prompt.contains("Do not run any commands"))
        #expect(!prompt.contains("amending"))
        #expect(!prompt.contains("truncated"))
    }

    @Test func promptWrapsDiffInSentinelMarkersNotFences() {
        // A markdown diff contains ``` lines as content; a fenced prompt
        // block would be closed early by them.
        let diff = "+```swift\n+let x = 1\n+```"
        let prompt = CommitMessageGenerator.prompt(diff: diff, amend: false, currentMessage: nil)
        #expect(prompt.contains("<<<BEGIN-DIFF>>>\n\(diff)\n<<<END-DIFF>>>"))
        #expect(!prompt.contains("```\n\(diff)"))
    }

    @Test func amendPromptCarriesCurrentMessage() {
        let prompt = CommitMessageGenerator.prompt(diff: "+x", amend: true, currentMessage: "Old subject")
        #expect(prompt.contains("amending the HEAD commit"))
        #expect(prompt.contains("Old subject"))
    }

    @Test func amendPromptWithoutMessageOmitsReferenceBlock() {
        let prompt = CommitMessageGenerator.prompt(diff: "+x", amend: true, currentMessage: "")
        #expect(prompt.contains("amending the HEAD commit"))
        #expect(!prompt.contains("current message"))
    }

    @Test func oversizedDiffPromptNotesTruncation() {
        let diff = String(repeating: "y", count: CommitMessageGenerator.diffCharacterLimit + 1)
        let prompt = CommitMessageGenerator.prompt(diff: diff, amend: false, currentMessage: nil)
        #expect(prompt.contains("truncated"))
    }
}
