import Foundation
import Testing
@testable import Gital

@MainActor
struct ReflogTests {
    private func line(hash: String, selector: String, subject: String) -> String {
        [hash, selector, subject].joined(separator: "\u{1f}")
    }

    @Test func parsesEntriesInOrder() {
        let output = [
            line(hash: "aaa111", selector: "HEAD@{5 minutes ago}", subject: "checkout: moving from main to aaa111"),
            line(hash: "bbb222", selector: "HEAD@{2 hours ago}", subject: "commit: Add reflog view"),
            line(hash: "ccc333", selector: "HEAD@{3 days ago}", subject: "reset: moving to HEAD~2"),
        ].joined(separator: "\n")

        let entries = GitRepository.parseReflog(output)
        #expect(entries.count == 3, "three entries parse")
        #expect(entries[0].hash == "aaa111" && entries[0].index == 0, "first entry is position 0")
        #expect(entries[0].selector == "HEAD@{0}", "selector derives from position, not the date field")
        #expect(entries[0].recordedDate == "5 minutes ago", "date extracted from the %gd braces")
        #expect(entries[1].subject == "commit: Add reflog view", "subject preserved")
        #expect(entries[2].index == 2, "positions follow list order")
    }

    // The subject is free text (commit subjects); a separator byte inside it
    // must not truncate the message.
    @Test func subjectContainingSeparatorSurvives() {
        let output = line(hash: "aaa111", selector: "HEAD@{now}", subject: "commit: weird\u{1f}subject")
        let entries = GitRepository.parseReflog(output)
        #expect(entries.count == 1, "entry parses")
        #expect(entries[0].subject == "commit: weird\u{1f}subject", "separator inside the subject is stitched back")
    }

    // `git update-ref HEAD HEAD` writes an entry with an empty message —
    // the trailing empty field must parse as an entry with subject "", not
    // be dropped (components(separatedBy:) keeps it; a refactor to
    // split(separator:) would silently start dropping these lines).
    @Test func emptySubjectParsesAsEntry() {
        let output = line(hash: "aaa111", selector: "HEAD@{0 seconds ago}", subject: "")
        let entries = GitRepository.parseReflog(output)
        #expect(entries.count == 1, "empty-subject entry is kept")
        #expect(entries.first?.subject == "", "subject stays empty")
        #expect(entries.first?.recordedDate == "0 seconds ago", "date still extracted")
    }

    @Test func malformedLinesAreSkipped() {
        let output = [
            "not-a-reflog-line",
            line(hash: "", selector: "HEAD@{now}", subject: "empty hash"),
            line(hash: "aaa111", selector: "HEAD@{1 minute ago}", subject: "commit: good"),
        ].joined(separator: "\n")

        let entries = GitRepository.parseReflog(output)
        #expect(entries.count == 1, "only the well-formed line survives")
        #expect(entries[0].hash == "aaa111", "surviving entry is the good one")
    }

    // A %gd shape without braces (defensive: git changing formats) falls back
    // to showing the raw field rather than nothing.
    @Test func dateWithoutBracesFallsBackToRawField() {
        let output = line(hash: "aaa111", selector: "yesterday", subject: "commit: x")
        let entries = GitRepository.parseReflog(output)
        #expect(entries.first?.recordedDate == "yesterday", "raw date field survives")
    }

    @Test func emptyOutputParsesToNoEntries() {
        #expect(GitRepository.parseReflog("").isEmpty, "empty reflog")
        #expect(GitRepository.parseReflog("\n").isEmpty, "blank line only")
    }

    // The same hash can appear at several positions (repeated checkouts) —
    // row identity must still be unique or SwiftUI collapses the rows.
    @Test func duplicateHashesKeepDistinctIdentity() {
        let output = [
            line(hash: "aaa111", selector: "HEAD@{1 hour ago}", subject: "checkout: moving from main to aaa111"),
            line(hash: "bbb222", selector: "HEAD@{2 hours ago}", subject: "checkout: moving from aaa111 to main"),
            line(hash: "aaa111", selector: "HEAD@{3 hours ago}", subject: "commit: Original"),
        ].joined(separator: "\n")

        let entries = GitRepository.parseReflog(output)
        let ids = Set(entries.map(\.id))
        #expect(ids.count == entries.count, "duplicate hashes get distinct ids")
    }
}
