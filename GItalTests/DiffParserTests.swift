import Foundation
import Testing
@testable import Gital

@MainActor
struct DiffParserTests {
    @Test func sampleDiff() throws {
        let diffs = DiffParser.parse(Fixtures.sampleDiff)
        #expect(diffs.count == 2, "DiffParser finds two files")
        #expect(diffs[0].path == "Sources/Login/LoginViewModel.swift", "DiffParser reads path")
        #expect(diffs[0].hunks.count == 1, "DiffParser reads one hunk")
        #expect(diffs[0].additions == 2, "DiffParser counts additions")
        #expect(diffs[0].deletions == 1, "DiffParser counts deletions")
        #expect(diffs[1].isBinary, "DiffParser flags binary files")

        let hunk = diffs[0].hunks[0]
        #expect(hunk.oldStart == 42 && hunk.newStart == 42, "DiffParser reads hunk ranges")
        let firstLine = hunk.lines[0]
        #expect(firstLine.kind == .context && firstLine.oldNumber == 42 && firstLine.newNumber == 42, "context line numbering")
        let deletion = try #require(hunk.lines.first { $0.kind == .deletion })
        #expect(deletion.oldNumber == 43 && deletion.newNumber == nil, "deletion line numbering")
        let addition = try #require(hunk.lines.first { $0.kind == .addition })
        #expect(addition.oldNumber == nil && addition.newNumber == 43, "addition line numbering")
    }

    // Hunk headers omit the count when a side is exactly one line (@@ -1 +1 @@).
    @Test func countlessHunkHeader() {
        let singleLineDiff = """
diff --git a/single.txt b/single.txt
index 1111111..2222222 100644
--- a/single.txt
+++ b/single.txt
@@ -1 +1 @@
-CLAUDE.md
\\ No newline at end of file
+CLAUDE.mds
\\ No newline at end of file
"""
        let singleLine = DiffParser.parse(singleLineDiff)
        #expect(singleLine.count == 1 && singleLine[0].hunks.count == 1, "countless hunk header parses")
        #expect(singleLine[0].deletions == 1 && singleLine[0].additions == 1, "countless hunk keeps deletion and addition")
        #expect(singleLine[0].hunks[0].lines[0].kind == .deletion && singleLine[0].hunks[0].lines[0].oldNumber == 1, "countless hunk numbering")
    }

    // Inside a hunk, "--- "/"+++ " are content (deleted "-- x" / added "++ x"),
    // not file headers.
    @Test func dashPrefixedContent() {
        let dashContentDiff = """
diff --git a/tricky.txt b/tricky.txt
index 1111111..2222222 100644
--- a/tricky.txt
+++ b/tricky.txt
@@ -1,4 +1,4 @@
--- CLAUDE.md comment
+-- CLAUDE.mds comment
 keep
-++ old thing
+++ new thing
 keep2
"""
        let dashContent = DiffParser.parse(dashContentDiff)
        #expect(dashContent.count == 1 && dashContent[0].path == "tricky.txt", "dash-prefixed content keeps file path")
        #expect(dashContent[0].deletions == 2 && dashContent[0].additions == 2, "dash-prefixed content lines survive")
        #expect(dashContent[0].hunks[0].lines[0].kind == .deletion && dashContent[0].hunks[0].lines[0].text == "-- CLAUDE.md comment", "leading --- line parsed as deletion")
        #expect(dashContent[0].hunks[0].lines[4].kind == .addition && dashContent[0].hunks[0].lines[4].text == "++ new thing", "leading +++ line parsed as addition")
    }

    // core.quotepath-style octal-escaped paths.
    @Test func quotedPaths() {
        let quotedPathDiff = """
diff --git "a/\\346\\227\\245\\346\\234\\254\\350\\252\\236.txt" "b/\\346\\227\\245\\346\\234\\254\\350\\252\\236.txt"
index 1111111..2222222 100644
--- "a/\\346\\227\\245\\346\\234\\254\\350\\252\\236.txt"
+++ "b/\\346\\227\\245\\346\\234\\254\\350\\252\\236.txt"
@@ -1 +1 @@
-hello
+hello world
"""
        let quotedPath = DiffParser.parse(quotedPathDiff)
        #expect(quotedPath.count == 1, "quoted path file is not dropped")
        #expect(quotedPath.first?.path == "日本語.txt", "quoted path is unescaped")
        #expect(quotedPath.first?.additions == 1 && quotedPath.first?.deletions == 1, "quoted path hunk parsed")
    }

    // Renames: pure rename has no hunks; edited rename reads paths from ---/+++.
    @Test func pureRename() {
        let renameDiff = """
diff --git a/Old.swift b/New.swift
similarity index 100%
rename from Old.swift
rename to New.swift
"""
        let renamed = DiffParser.parse(renameDiff)
        #expect(renamed.count == 1 && renamed[0].path == "New.swift" && renamed[0].oldPath == "Old.swift", "pure rename keeps both paths")
    }

    @Test func untrackedNewFile() {
        let untracked = DiffParser.parse(Fixtures.untrackedDiff)
        #expect(untracked.count == 1 && untracked[0].path == "new.txt" && untracked[0].additions == 2, "untracked new-file diff parses")
    }

    @Test func combinedDiff() {
        let combined = DiffParser.parse(Fixtures.combinedDiff)
        #expect(combined.count == 1 && combined[0].path == "file.txt", "combined diff reads path")
        #expect(combined[0].hunks.count == 1, "combined hunk header parses")
        #expect(combined[0].additions == 6 && combined[0].deletions == 0, "combined lines classified")
        let combinedLines = combined[0].hunks[0].lines
        #expect(combinedLines[0].kind == .context && combinedLines[0].oldNumber == 1 && combinedLines[0].newNumber == 1, "combined context numbering")
        #expect(combinedLines[1].kind == .addition && combinedLines[1].text == "<<<<<<< HEAD" && combinedLines[1].newNumber == 2, "combined conflict marker is addition")
        #expect(combinedLines[6].kind == .context && combinedLines[6].oldNumber == 3 && combinedLines[6].newNumber == 7, "combined first-parent old numbering")
    }

    @Test func noNewlineMarkers() {
        let noNewline = DiffParser.parse(Fixtures.noNewlineDiff)
        #expect(noNewline[0].hunks[0].lines[1].noNewline && noNewline[0].hunks[0].lines[2].noNewline, "parser keeps no-newline markers")
    }

    // Scope flows from the diff source into the parsed files.
    @Test func scopeTagging() {
        #expect(DiffParser.parse(Fixtures.sampleDiff, scope: .unstaged)[0].scope == .unstaged, "parse tags scope")
        #expect(DiffParser.parse(Fixtures.sampleDiff)[0].scope == .snapshot, "scope defaults to snapshot")
    }

    @Test func splitRows() {
        let diffs = DiffParser.parse(Fixtures.sampleDiff)
        let rows = SplitDiffRow.rows(for: diffs[0].hunks)
        #expect(rows[0].isHunkHeader, "split rows start with hunk header")
        let paired = rows.first { $0.left.kind == .deletion && $0.right.kind == .addition }
        #expect(paired != nil, "split rows pair deletion with addition")
    }

    // Regression: a change in one file must never shift another file's line
    // IDs, or a kept selection silently points at different physical lines
    // after a reload.
    @Test func lineIDsArePerFile() {
        let fileBDiff = """
diff --git a/b.txt b/b.txt
index 1111111..2222222 100644
--- a/b.txt
+++ b/b.txt
@@ -1,2 +1,2 @@
 ctx
-x
+y
"""
        let fileADiff = """
diff --git a/a.txt b/a.txt
index 1111111..2222222 100644
--- a/a.txt
+++ b/a.txt
@@ -1,3 +1,4 @@
 keep
+added
 keep2
 keep3
"""
        let combinedAB = DiffParser.parse(fileADiff + "\n" + fileBDiff)
        let bAlone = DiffParser.parse(fileBDiff)
        #expect(combinedAB.count == 2, "two-file diff parses both files")
        #expect(combinedAB[1].hunks[0].lines.map(\.id) == bAlone[0].hunks[0].lines.map(\.id),
                "a file's line IDs are independent of preceding files")
    }

    // Regression: renames and binaries with spaces.
    @Test func spacedRenameAndBinary() {
        let spacedRename = DiffParser.parse("""
diff --git a/old name.txt b/new name.txt
similarity index 100%
rename from old name.txt
rename to new name.txt
""")
        #expect(spacedRename.count == 1 && spacedRename[0].path == "new name.txt" && spacedRename[0].oldPath == "old name.txt",
                "pure rename with spaces reads paths from rename from/to lines")

        let spacedBinary = DiffParser.parse("""
diff --git a/my file.png b/my file.png
index 3333333..4444444 100644
Binary files a/my file.png and b/my file.png differ
""")
        #expect(spacedBinary.count == 1 && spacedBinary[0].path == "my file.png" && spacedBinary[0].isBinary,
                "binary file with spaces keeps its full name")
    }
}
