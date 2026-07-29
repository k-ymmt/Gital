import Foundation
import Testing
@testable import Gital

@MainActor
struct FileHistoryParsingTests {
    /// Builds one `log --follow --name-status` record as git emits it: a
    /// leading NUL, NUL-separated fields, then the name-status block.
    private func record(_ hash: String, _ author: String, _ subject: String, nameStatus: String?) -> String {
        var text = "\u{0}\(hash)\u{0}\(author)\u{0}\(author)@example.com\u{0}2 days ago\u{0}\(subject)"
        if let nameStatus {
            text += "\n\(nameStatus)\n"
        }
        return text
    }

    @Test func renameChainTracking() {
        let output =
            record("a1", "Alice", "Rename it", nameStatus: "R100\tOld/Name.swift\tNew/Name.swift")
            + "\n"
            + record("b2", "Bob", "Edit old", nameStatus: "M\tOld/Name.swift")
            + "\n"
            + record("c3", "Carol", "Add file", nameStatus: "A\tOld/Name.swift")

        let entries = GitRepository.parseFileHistory(output, queryPath: "New/Name.swift")
        #expect(entries.count == 3, "one entry per commit")

        #expect(entries[0].hash == "a1" && entries[0].subject == "Rename it", "newest entry fields")
        #expect(entries[0].status == .renamed, "rename status")
        #expect(entries[0].path == "New/Name.swift", "rename entry keeps new path")
        #expect(entries[0].previousPath == "Old/Name.swift", "rename entry records old path")

        #expect(entries[1].path == "Old/Name.swift" && entries[1].previousPath == nil, "pre-rename commit uses old path")
        #expect(entries[1].status == .modified, "modified status")
        #expect(entries[2].status == .added, "added status")
    }

    // A merge commit shows no name-status block; the entry must fall back to
    // the path the file goes by at that point in the walk.
    @Test func recordWithoutNameStatus() {
        let output =
            record("a1", "Alice", "Merge branch 'x'", nameStatus: nil)
            + "\n"
            + record("b2", "Bob", "Edit", nameStatus: "M\tDocs/readme.md")

        let entries = GitRepository.parseFileHistory(output, queryPath: "Docs/readme.md")
        #expect(entries.count == 2, "merge record still parsed")
        #expect(entries[0].path == "Docs/readme.md", "merge entry keeps tracked path")
        #expect(entries[0].status == .modified, "merge entry defaults to modified")
    }

    // Subjects can contain anything but NUL and newline — including tabs and
    // text that looks like a name-status line.
    @Test func hostileSubject() {
        let output = record("a1", "Alice", "M\tweird subject", nameStatus: "M\tfile.txt")
        let entries = GitRepository.parseFileHistory(output, queryPath: "file.txt")
        #expect(entries.count == 1 && entries[0].subject == "M\tweird subject", "subject survives verbatim")
        #expect(entries[0].path == "file.txt", "path taken from name-status, not subject")
    }

    @Test func quotedPathsUnquoted() {
        let output = record("a1", "Alice", "Rename", nameStatus: "R100\t\"Old\\tName.swift\"\tNew.swift")
        let entries = GitRepository.parseFileHistory(output, queryPath: "New.swift")
        #expect(entries[0].previousPath == "Old\tName.swift", "escaped tab unquoted")
    }

    @Test func unquotePath() {
        #expect(GitRepository.unquotePath("plain/path.swift") == "plain/path.swift", "unquoted path untouched")
        #expect(GitRepository.unquotePath("\"a\\tb\"") == "a\tb", "tab escape")
        #expect(GitRepository.unquotePath("\"a\\\\b\\\"c\"") == "a\\b\"c", "backslash and quote escapes")
        #expect(GitRepository.unquotePath("\"\\346\\227\\245.txt\"") == "日.txt", "octal escapes decode as UTF-8")
    }
}

@MainActor
struct BlameParsingTests {
    private static let zeroHash = String(repeating: "0", count: 40)
    private static let hashA = String(repeating: "a", count: 40)
    private static let hashB = String(repeating: "b", count: 40)

    private var sample: String {
        """
        \(Self.hashA) 1 1 2
        author Alice
        author-mail <alice@example.com>
        author-time 0
        author-tz +0000
        committer Alice
        committer-mail <alice@example.com>
        committer-time 0
        committer-tz +0000
        summary First commit
        filename file.txt
        \tline one
        \(Self.hashA) 2 2
        \tline two
        \(Self.hashB) 3 3 1
        author Bob
        author-mail <bob@example.com>
        author-time 82800
        author-tz +0900
        committer Bob
        committer-mail <bob@example.com>
        committer-time 82800
        committer-tz +0900
        summary Second commit
        previous \(Self.hashA) file.txt
        filename file.txt
        \tline three
        \(Self.zeroHash) 4 4 1
        author Not Committed Yet
        author-mail <not.committed.yet>
        author-time 82800
        author-tz +0900
        committer Not Committed Yet
        committer-mail <not.committed.yet>
        committer-time 82800
        committer-tz +0900
        summary Version of file.txt from file.txt
        filename file.txt
        \t
        """
    }

    @Test func porcelainParsing() {
        let blame = GitRepository.parseBlame(sample)
        #expect(blame.lines.count == 4, "one BlameLine per content line")
        #expect(blame.lines.map(\.number) == [1, 2, 3, 4], "final line numbers")
        #expect(blame.lines.map(\.isGroupStart) == [true, false, true, true], "group starts where headers carry a length")
        #expect(blame.lines[0].text == "line one" && blame.lines[3].text == "", "content after the tab, verbatim")
        #expect(blame.lines[1].hash == Self.hashA, "short header lines reuse the commit")
        #expect(blame.lines[3].isUncommitted, "zero hash flags an uncommitted line")

        let alice = blame.annotations[Self.hashA]
        #expect(alice?.author == "Alice" && alice?.summary == "First commit", "annotation metadata")
        #expect(alice?.date == "1970-01-01", "epoch 0 at +0000")
        // 82800 = 23:00 UTC on Jan 1 — already Jan 2 in the author's +0900.
        #expect(blame.annotations[Self.hashB]?.date == "1970-01-02", "date rendered in the author's zone")
    }

    @Test func blameDateOffsets() {
        #expect(GitRepository.blameDate(epoch: "82800", timeZone: "+0900") == "1970-01-02", "positive offset")
        #expect(GitRepository.blameDate(epoch: "82800", timeZone: "-0100") == "1970-01-01", "negative offset")
        #expect(GitRepository.blameDate(epoch: "82800", timeZone: nil) == "1970-01-01", "missing zone falls back to UTC")
        #expect(GitRepository.blameDate(epoch: nil, timeZone: "+0000") == "", "missing epoch yields empty")
        #expect(GitRepository.blameDate(epoch: "junk", timeZone: "+0000") == "", "non-numeric epoch yields empty")
    }
}
