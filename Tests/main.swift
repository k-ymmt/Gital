// Standalone test runner for the git parsing layer.
// Run with Scripts/run-tests.sh (compiles Git/*.swift + this file with swiftc).

import Foundation

var failures = 0

func expect(_ condition: Bool, _ label: String, file: String = #file, line: Int = #line) {
    if condition {
        print("✓ \(label)")
    } else {
        failures += 1
        print("✗ \(label)  (\(file):\(line))")
    }
}

// MARK: - DiffParser

let sampleDiff = """
diff --git a/Sources/Login/LoginViewModel.swift b/Sources/Login/LoginViewModel.swift
index 1111111..2222222 100644
--- a/Sources/Login/LoginViewModel.swift
+++ b/Sources/Login/LoginViewModel.swift
@@ -42,5 +42,6 @@ final class LoginViewModel {
     func validate(token: String) -> Bool {
-        return !token.isEmpty
+        guard !token.isEmpty else { return false }
+        return token.count >= minTokenLength
     }
 }
diff --git a/Resources/logo.png b/Resources/logo.png
index 3333333..4444444 100644
Binary files a/Resources/logo.png and b/Resources/logo.png differ
"""

let diffs = DiffParser.parse(sampleDiff)
expect(diffs.count == 2, "DiffParser finds two files")
expect(diffs[0].path == "Sources/Login/LoginViewModel.swift", "DiffParser reads path")
expect(diffs[0].hunks.count == 1, "DiffParser reads one hunk")
expect(diffs[0].additions == 2, "DiffParser counts additions")
expect(diffs[0].deletions == 1, "DiffParser counts deletions")
expect(diffs[1].isBinary, "DiffParser flags binary files")

let hunk = diffs[0].hunks[0]
expect(hunk.oldStart == 42 && hunk.newStart == 42, "DiffParser reads hunk ranges")
let firstLine = hunk.lines[0]
expect(firstLine.kind == .context && firstLine.oldNumber == 42 && firstLine.newNumber == 42, "context line numbering")
let deletion = hunk.lines.first { $0.kind == .deletion }!
expect(deletion.oldNumber == 43 && deletion.newNumber == nil, "deletion line numbering")
let addition = hunk.lines.first { $0.kind == .addition }!
expect(addition.oldNumber == nil && addition.newNumber == 43, "addition line numbering")

// MARK: - DiffParser edge cases

// Hunk headers omit the count when a side is exactly one line (@@ -1 +1 @@).
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
expect(singleLine.count == 1 && singleLine[0].hunks.count == 1, "countless hunk header parses")
expect(singleLine[0].deletions == 1 && singleLine[0].additions == 1, "countless hunk keeps deletion and addition")
expect(singleLine[0].hunks[0].lines[0].kind == .deletion && singleLine[0].hunks[0].lines[0].oldNumber == 1, "countless hunk numbering")

// Inside a hunk, "--- "/"+++ " are content (deleted "-- x" / added "++ x"),
// not file headers.
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
expect(dashContent.count == 1 && dashContent[0].path == "tricky.txt", "dash-prefixed content keeps file path")
expect(dashContent[0].deletions == 2 && dashContent[0].additions == 2, "dash-prefixed content lines survive")
expect(dashContent[0].hunks[0].lines[0].kind == .deletion && dashContent[0].hunks[0].lines[0].text == "-- CLAUDE.md comment", "leading --- line parsed as deletion")
expect(dashContent[0].hunks[0].lines[4].kind == .addition && dashContent[0].hunks[0].lines[4].text == "++ new thing", "leading +++ line parsed as addition")

// core.quotepath-style octal-escaped paths.
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
expect(quotedPath.count == 1, "quoted path file is not dropped")
expect(quotedPath.first?.path == "日本語.txt", "quoted path is unescaped")
expect(quotedPath.first?.additions == 1 && quotedPath.first?.deletions == 1, "quoted path hunk parsed")

// Renames: pure rename has no hunks; edited rename reads paths from ---/+++.
let renameDiff = """
diff --git a/Old.swift b/New.swift
similarity index 100%
rename from Old.swift
rename to New.swift
"""
let renamed = DiffParser.parse(renameDiff)
expect(renamed.count == 1 && renamed[0].path == "New.swift" && renamed[0].oldPath == "Old.swift", "pure rename keeps both paths")

// New file via diff --no-index (untracked preview).
let untrackedDiff = """
diff --git a/new.txt b/new.txt
new file mode 100644
index 0000000..ebb3a2b
--- /dev/null
+++ b/new.txt
@@ -0,0 +1,2 @@
+CLAUDE.md
+line2
"""
let untracked = DiffParser.parse(untrackedDiff)
expect(untracked.count == 1 && untracked[0].path == "new.txt" && untracked[0].additions == 2, "untracked new-file diff parses")

// Combined diff for a conflicted path ("git diff" during a merge).
let combinedDiff = """
diff --cc file.txt
index 1e427e4,c08134a..0000000
--- a/file.txt
+++ b/file.txt
@@@ -1,3 -1,4 +1,8 @@@
  line1
++<<<<<<< HEAD
 +main change
++=======
+ feature change
++>>>>>>> feature
  line3
+ feature tail
"""
let combined = DiffParser.parse(combinedDiff)
expect(combined.count == 1 && combined[0].path == "file.txt", "combined diff reads path")
expect(combined[0].hunks.count == 1, "combined hunk header parses")
expect(combined[0].additions == 6 && combined[0].deletions == 0, "combined lines classified")
let combinedLines = combined[0].hunks[0].lines
expect(combinedLines[0].kind == .context && combinedLines[0].oldNumber == 1 && combinedLines[0].newNumber == 1, "combined context numbering")
expect(combinedLines[1].kind == .addition && combinedLines[1].text == "<<<<<<< HEAD" && combinedLines[1].newNumber == 2, "combined conflict marker is addition")
expect(combinedLines[6].kind == .context && combinedLines[6].oldNumber == 3 && combinedLines[6].newNumber == 7, "combined first-parent old numbering")

// MARK: - PatchBuilder

let rebuiltPatch = PatchBuilder.hunkPatch(for: diffs[0].hunks[0], in: diffs[0])
let expectedPatch = """
--- a/Sources/Login/LoginViewModel.swift
+++ b/Sources/Login/LoginViewModel.swift
@@ -42,5 +42,6 @@ final class LoginViewModel {
     func validate(token: String) -> Bool {
-        return !token.isEmpty
+        guard !token.isEmpty else { return false }
+        return token.count >= minTokenLength
    \u{20}}
\u{20}}

"""
expect(rebuiltPatch == expectedPatch, "PatchBuilder round-trips a hunk")

// A file without a trailing newline must keep the "\ No newline" marker,
// otherwise git apply rejects the rebuilt patch.
let noNewlineDiff = """
diff --git a/end.txt b/end.txt
index 1111111..2222222 100644
--- a/end.txt
+++ b/end.txt
@@ -1,2 +1,2 @@
 first
-old last
\\ No newline at end of file
+new last
\\ No newline at end of file
"""
let noNewline = DiffParser.parse(noNewlineDiff)
expect(noNewline[0].hunks[0].lines[1].noNewline && noNewline[0].hunks[0].lines[2].noNewline, "parser keeps no-newline markers")
let noNewlinePatch = PatchBuilder.hunkPatch(for: noNewline[0].hunks[0], in: noNewline[0])
expect(noNewlinePatch == noNewlineDiff.split(separator: "\n").dropFirst(2).joined(separator: "\n") + "\n", "PatchBuilder re-emits no-newline markers")

// Partial patches can't express renames or combined conflict hunks.
expect(PatchBuilder.hunkPatch(for: combined[0].hunks[0], in: combined[0]) == nil, "PatchBuilder refuses combined hunks")
let renameWithHunk = FileDiff(path: "New.swift", oldPath: "Old.swift", isBinary: false, hunks: diffs[0].hunks)
expect(PatchBuilder.hunkPatch(for: diffs[0].hunks[0], in: renameWithHunk) == nil, "PatchBuilder refuses renames")
let binaryWithHunk = FileDiff(path: "logo.png", oldPath: nil, isBinary: true, hunks: diffs[0].hunks)
expect(PatchBuilder.hunkPatch(for: diffs[0].hunks[0], in: binaryWithHunk) == nil, "PatchBuilder refuses binary files")

// Paths with characters that break the patch format get C-quoted like git does.
let trickyDiff = FileDiff(path: "we\"ird.txt", oldPath: nil, isBinary: false, hunks: noNewline[0].hunks)
expect(PatchBuilder.hunkPatch(for: noNewline[0].hunks[0], in: trickyDiff)?.hasPrefix("--- \"a/we\\\"ird.txt\"\n") == true, "PatchBuilder quotes tricky paths")

// Scope flows from the diff source into the parsed files.
expect(DiffParser.parse(sampleDiff, scope: .unstaged)[0].scope == .unstaged, "parse tags scope")
expect(diffs[0].scope == .snapshot, "scope defaults to snapshot")

// MARK: - PatchBuilder line selection

// Staging one addition: the other addition is omitted (not in the index yet)
// and the unpicked deletion becomes context (still in the index).
let guardLine = diffs[0].hunks[0].lines.first { $0.text.contains("guard") }!
let stageOnePatch = PatchBuilder.linesPatch(for: diffs[0], selecting: [guardLine.id], direction: .stage)
let expectedStageOne = """
--- a/Sources/Login/LoginViewModel.swift
+++ b/Sources/Login/LoginViewModel.swift
@@ -42,4 +42,5 @@
     func validate(token: String) -> Bool {
         return !token.isEmpty
+        guard !token.isEmpty else { return false }
    \u{20}}
\u{20}}

"""
expect(stageOnePatch == expectedStageOne, "linesPatch stages a single addition")

// Unstaging one deletion: unpicked additions stay in the index as context.
let deletionLine = diffs[0].hunks[0].lines.first { $0.kind == .deletion }!
let unstageOnePatch = PatchBuilder.linesPatch(for: diffs[0], selecting: [deletionLine.id], direction: .unstage)
expect(unstageOnePatch?.contains("@@ -42,6 +42,5 @@") == true, "linesPatch recounts for unstage")
expect(unstageOnePatch?.contains("-        return !token.isEmpty") == true, "linesPatch keeps selected deletion")
expect(unstageOnePatch?.contains("\n+        guard") == false
    && unstageOnePatch?.contains("\n         guard !token.isEmpty else { return false }") == true,
    "linesPatch neutralizes unpicked additions into context")

// Discarding reuses the unstage shape (reverse-applied to the worktree instead
// of the index): selecting one addition keeps the other addition as context and
// omits the unpicked deletion, so only the picked line is reverted.
let countLine = diffs[0].hunks[0].lines.first { $0.text.contains("minTokenLength") }!
let discardOnePatch = PatchBuilder.linesPatch(for: diffs[0], selecting: [countLine.id], direction: .unstage)
let expectedDiscardOne = """
--- a/Sources/Login/LoginViewModel.swift
+++ b/Sources/Login/LoginViewModel.swift
@@ -42,4 +42,5 @@
     func validate(token: String) -> Bool {
         guard !token.isEmpty else { return false }
+        return token.count >= minTokenLength
    \u{20}}
\u{20}}

"""
expect(discardOnePatch == expectedDiscardOne, "linesPatch builds a single-addition discard patch")

// Hunks without any selected line are dropped from the patch.
let twoHunkDiff = DiffParser.parse("""
diff --git a/two.txt b/two.txt
index 1111111..2222222 100644
--- a/two.txt
+++ b/two.txt
@@ -1,3 +1,3 @@
 a
-b
+B
 c
@@ -10,3 +10,3 @@
 x
-y
+Y
 z
""")[0]
let yLine = twoHunkDiff.hunks[1].lines.first { $0.text == "Y" }!
let secondHunkOnly = PatchBuilder.linesPatch(for: twoHunkDiff, selecting: [yLine.id], direction: .stage)
expect(secondHunkOnly?.contains("@@ -10,3 +10,4 @@") == true, "linesPatch recounts the selected hunk")
expect(secondHunkOnly?.contains("-b") == false && secondHunkOnly?.components(separatedBy: "@@ -").count == 2, "linesPatch drops unselected hunks")

// Selecting nothing applicable yields no patch.
let contextLine = diffs[0].hunks[0].lines.first { $0.kind == .context }!
expect(PatchBuilder.linesPatch(for: diffs[0], selecting: [contextLine.id], direction: .stage) == nil, "linesPatch ignores context-only selection")
expect(PatchBuilder.linesPatch(for: diffs[0], selecting: [], direction: .stage) == nil, "linesPatch rejects empty selection")

// MARK: - Split rows

let splitRows = SplitDiffRow.rows(for: diffs[0].hunks)
expect(splitRows[0].isHunkHeader, "split rows start with hunk header")
let paired = splitRows.first { $0.left.kind == .deletion && $0.right.kind == .addition }
expect(paired != nil, "split rows pair deletion with addition")

// MARK: - Status parsing

var statusData = Data()
for token in [
    "# branch.oid 0123456789abcdef",
    "# branch.head feature/onboarding",
    "# branch.upstream origin/feature/onboarding",
    "# branch.ab +2 -1",
    "1 .M N... 100644 100644 100644 aaaa bbbb Sources/App/AppDelegate.swift",
    "1 M. N... 100644 100644 100644 aaaa bbbb Sources/Onboarding/OnboardingCarousel.swift",
    "2 R. N... 100644 100644 100644 aaaa bbbb R100 Sources/New.swift",
    "Sources/Old.swift",
    "? Resources/welcome_1.png",
] {
    statusData.append(token.data(using: .utf8)!)
    statusData.append(0)
}

let status = GitRepository.parseStatus(statusData)
expect(status.branch == "feature/onboarding", "status branch")
expect(status.upstream == "origin/feature/onboarding", "status upstream")
expect(status.ahead == 2 && status.behind == 1, "status ahead/behind")
expect(status.unstaged.count == 2, "status unstaged count")
expect(status.staged.count == 2, "status staged count")
expect(status.staged.contains { $0.path == "Sources/New.swift" && $0.originalPath == "Sources/Old.swift" && $0.status == .renamed }, "status rename entry")
expect(status.unstaged.contains { $0.path == "Resources/welcome_1.png" && $0.status == .untracked }, "status untracked entry")

// MARK: - Log parsing

let logOutput = [
    ["aaa111", "bbb222", "Kenji Mori", "kenji@aurora.app", "2 hours ago", "Polish welcome carousel", "HEAD -> feature/onboarding, origin/feature/onboarding"].joined(separator: "\u{0}"),
    ["bbb222", "ccc333 ddd444", "Aiko Tanaka", "aiko@aurora.app", "Yesterday", "Merge branch 'main'", "tag: v1.2.0, main"].joined(separator: "\u{0}"),
].joined(separator: "\n")

let commits = GitRepository.parseLog(logOutput, remotes: ["origin"])
expect(commits.count == 2, "log parses two commits")
expect(commits[0].refs.contains { $0.kind == .head && $0.name == "feature/onboarding" }, "log HEAD ref")
expect(commits[0].refs.contains { $0.kind == .remoteBranch && $0.name == "origin/feature/onboarding" }, "log remote ref")
expect(commits[1].parents == ["ccc333", "ddd444"], "log merge parents")
expect(commits[1].refs.contains { $0.kind == .tag && $0.name == "v1.2.0" }, "log tag ref")
expect(commits[1].refs.contains { $0.kind == .branch && $0.name == "main" }, "log branch ref")

// Local branches containing "/" must not be mistaken for remote branches.
expect(GitRepository.parseRefs("feature/login", remotes: ["origin"]).first?.kind == .branch, "slash-named local branch stays local")
expect(GitRepository.parseRefs("origin/main", remotes: ["origin"]).first?.kind == .remoteBranch, "known remote prefix is remote")

// A subject containing legacy 0x1E/0x1F separator bytes must not corrupt
// record splitting (NUL separators make this impossible).
let hostileLog = ["eee555", "", "Mallory", "m@x", "now", "subject with \u{1e} and \u{1f} bytes", ""].joined(separator: "\u{0}")
let hostileCommits = GitRepository.parseLog(hostileLog)
expect(hostileCommits.count == 1 && hostileCommits[0].subject == "subject with \u{1e} and \u{1f} bytes", "hostile subject bytes survive log parsing")

// MARK: - Commit detail parsing

let detailOutput = [
    "aaa111bbb222ccc333ddd444eee555fff666aaa1",
    "p1p1p1 p2p2p2",
    "Kenji Mori", "kenji@aurora.app", "2026-07-25 10:30:00",
    "GitHub", "noreply@github.com", "2026-07-25 11:00:00",
    "HEAD -> main, tag: v2.0.0",
    "Polish welcome carousel\n\nMulti-line body with details.\nSecond body line.\n",
].joined(separator: "\u{0}")

let detail = GitRepository.parseCommitDetail(detailOutput, remotes: ["origin"])
expect(detail != nil, "commit detail parses")
expect(detail?.hash == "aaa111bbb222ccc333ddd444eee555fff666aaa1", "detail full hash")
expect(detail?.parents == ["p1p1p1", "p2p2p2"], "detail parents")
expect(detail?.author == "Kenji Mori" && detail?.authorDate == "2026-07-25 10:30:00", "detail author fields")
expect(detail?.hasDistinctCommitter == true, "detail distinct committer detected")
expect(detail?.message == "Polish welcome carousel\n\nMulti-line body with details.\nSecond body line.", "detail multi-line message survives NUL splitting")
expect(detail?.refs.contains { $0.kind == .head && $0.name == "main" } == true, "detail HEAD ref")
expect(detail?.refs.contains { $0.kind == .tag && $0.name == "v2.0.0" } == true, "detail tag ref")

let sameCommitterDetail = GitRepository.parseCommitDetail([
    "abc", "", "A", "a@a", "2026-01-01 00:00:00", "A", "a@a", "2026-01-01 00:00:00", "", "msg",
].joined(separator: "\u{0}"))
expect(sameCommitterDetail?.hasDistinctCommitter == false, "detail same committer not flagged")
expect(GitRepository.parseCommitDetail("") == nil, "empty detail output yields nil")

// MARK: - Commit graph

func makeCommit(_ hash: String, _ parents: [String]) -> Commit {
    Commit(hash: hash, parents: parents, author: "A", authorEmail: "a@a", relativeDate: "now", subject: hash, body: "", refs: [])
}

// A -> B -> C(merge of D,E) ; D -> F ; E -> F ; F
let graphCommits = [
    makeCommit("A", ["B"]),
    makeCommit("B", ["C"]),
    makeCommit("C", ["D", "E"]),
    makeCommit("D", ["F"]),
    makeCommit("E", ["F"]),
    makeCommit("F", []),
]
let graph = CommitGraph(commits: graphCommits)
expect(graph.rows.count == 6, "graph has a row per commit")
expect(graph.rows["A"]!.dotLane == 0, "first commit in lane 0")
expect(graph.rows["C"]!.edges.contains { if case .branchOut = $0.shape { return true }; return false }, "merge commit branches out")
expect(graph.rows["E"]!.dotLane == 1, "second parent occupies lane 1")
expect(graph.maxLanes >= 2, "graph tracks max lanes")
let mergeBack = graph.rows["F"]!.edges.contains { if case .mergeIn = $0.shape { return true }; return false }
expect(mergeBack, "lanes merge back into common parent")

// MARK: - Regression: /dev/null patch headers

// Staging every deletion line of a deleted file must produce a deletion
// (`+++ /dev/null`), not an empty file staged under `b/path`.
let deletedFileDiff = DiffParser.parse("""
diff --git a/del.txt b/del.txt
deleted file mode 100644
index 1111111..0000000
--- a/del.txt
+++ /dev/null
@@ -1,2 +0,0 @@
-one
-two
""", scope: .unstaged)[0]
let allDeleteIDs = Set(deletedFileDiff.hunks[0].lines.map(\.id))
let fullDeletePatch = PatchBuilder.linesPatch(for: deletedFileDiff, selecting: allDeleteIDs, direction: .stage)
expect(fullDeletePatch?.contains("+++ /dev/null") == true, "full deletion patch targets /dev/null")
expect(fullDeletePatch?.contains("--- a/del.txt") == true, "full deletion patch keeps the old path")

let firstDeleteID = deletedFileDiff.hunks[0].lines[0].id
let partialDeletePatch = PatchBuilder.linesPatch(for: deletedFileDiff, selecting: [firstDeleteID], direction: .stage)
expect(partialDeletePatch?.contains("+++ b/del.txt") == true, "partial deletion patch stays a modification")

let untrackedIDs = Set(untracked[0].hunks[0].lines.map(\.id))
let createPatch = PatchBuilder.linesPatch(for: untracked[0], selecting: untrackedIDs, direction: .stage)
expect(createPatch?.hasPrefix("--- /dev/null\n+++ b/new.txt\n") == true, "file creation patch sources /dev/null")
expect(PatchBuilder.hunkPatch(for: untracked[0].hunks[0], in: untracked[0])?.hasPrefix("--- /dev/null\n") == true, "hunkPatch sources /dev/null for creations")

// MARK: - Regression: no-newline-at-EOF line selections

// Partial selections that would move a "\ No newline" marker off the final
// line of its side cannot be expressed as a valid patch — git apply would
// corrupt the target (concatenate lines) or reject the patch. They must be
// refused instead of built wrong.
let nnLines = noNewline[0].hunks[0].lines
let nnDeletion = nnLines.first { $0.kind == .deletion }!
let nnAddition = nnLines.first { $0.kind == .addition }!
expect(PatchBuilder.linesPatch(for: noNewline[0], selecting: [nnAddition.id], direction: .stage) == nil,
       "staging only the addition at a no-newline EOF is refused")
expect(PatchBuilder.linesPatch(for: noNewline[0], selecting: [nnDeletion.id], direction: .unstage) == nil,
       "discarding only the deletion at a no-newline EOF is refused")
let nnDeleteOnly = PatchBuilder.linesPatch(for: noNewline[0], selecting: [nnDeletion.id], direction: .stage)
expect(nnDeleteOnly?.contains("-old last\n\\ No newline at end of file\n") == true,
       "staging only the deletion keeps a valid trailing marker")
let nnBoth = PatchBuilder.linesPatch(for: noNewline[0], selecting: [nnDeletion.id, nnAddition.id], direction: .stage)
expect(nnBoth?.hasSuffix("+new last\n\\ No newline at end of file\n") == true,
       "full selection round-trips both markers")

// MARK: - Regression: line IDs are per-file

// A change in one file must never shift another file's line IDs, or a kept
// selection silently points at different physical lines after a reload.
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
expect(combinedAB.count == 2, "two-file diff parses both files")
expect(combinedAB[1].hunks[0].lines.map(\.id) == bAlone[0].hunks[0].lines.map(\.id),
       "a file's line IDs are independent of preceding files")

// MARK: - Regression: status conflict/detached/spaces

var statusData2 = Data()
for token in [
    "# branch.head (detached)",
    "1 .M N... 100644 100644 100644 aaaa bbbb My File.txt",
    "u UU N... 100644 100644 100644 100644 aaaa bbbb cccc Merge Conflict.swift",
] {
    statusData2.append(token.data(using: .utf8)!)
    statusData2.append(0)
}
let status2 = GitRepository.parseStatus(statusData2)
expect(status2.branch == nil, "detached HEAD parses as nil branch")
expect(status2.unstaged.contains { $0.path == "My File.txt" && $0.status == .modified }, "path with spaces survives status parsing")
expect(status2.unstaged.contains { $0.path == "Merge Conflict.swift" && $0.status == .conflicted }, "conflicted u entry parses")

// MARK: - Regression: renames and binaries with spaces

let spacedRename = DiffParser.parse("""
diff --git a/old name.txt b/new name.txt
similarity index 100%
rename from old name.txt
rename to new name.txt
""")
expect(spacedRename.count == 1 && spacedRename[0].path == "new name.txt" && spacedRename[0].oldPath == "old name.txt",
       "pure rename with spaces reads paths from rename from/to lines")

let spacedBinary = DiffParser.parse("""
diff --git a/my file.png b/my file.png
index 3333333..4444444 100644
Binary files a/my file.png and b/my file.png differ
""")
expect(spacedBinary.count == 1 && spacedBinary[0].path == "my file.png" && spacedBinary[0].isBinary,
       "binary file with spaces keeps its full name")

// MARK: - Regression: commit stats parse renames via -z

var numstatZ = Data()
for token in ["5\t2\t", "old dir/old.txt", "new dir/new.txt", "1\t0\tplain.txt"] {
    numstatZ.append(token.data(using: .utf8)!)
    numstatZ.append(0)
}
var nameStatusZ = Data()
for token in ["R100", "old dir/old.txt", "new dir/new.txt", "M", "plain.txt"] {
    nameStatusZ.append(token.data(using: .utf8)!)
    nameStatusZ.append(0)
}
let commitStats = GitRepository.parseCommitStats(numstat: numstatZ, nameStatus: nameStatusZ)
expect(commitStats.contains { $0.path == "new dir/new.txt" && $0.oldPath == "old dir/old.txt" && $0.status == .renamed && $0.additions == 5 && $0.deletions == 2 },
       "renamed file stat keeps both real paths")
expect(commitStats.contains { $0.path == "plain.txt" && $0.status == .modified && $0.additions == 1 },
       "plain file stat parses alongside a rename")

// MARK: - Regression: graph continuity at branch points

// Two commits sharing a first parent put the same hash in two lanes; each
// lane must continue straight down instead of zigzagging into the other copy.
let branchCommits = [
    makeCommit("C1", ["P"]),
    makeCommit("C2", ["P"]),
    makeCommit("C3", ["Q"]),
    makeCommit("P", ["Q"]),
    makeCommit("Q", []),
]
let branchGraph = CommitGraph(commits: branchCommits)
let c3Edges = branchGraph.rows["C3"]!.edges
expect(c3Edges.contains { $0.shape == .passThrough(lane: 1) }, "duplicate parent lane passes straight through")
expect(!c3Edges.contains { if case .laneShift = $0.shape { return true }; return false }, "no spurious lane shift at a branch point")
let pEdges = branchGraph.rows["P"]!.edges
expect(pEdges.contains { $0.shape == .passThrough(lane: 2) }, "unrelated lane passes through the branch parent row")
expect(pEdges.contains { $0.shape == .mergeIn(fromLane: 1) }, "duplicate lane merges into the parent dot")

// Parents outside the loaded window (log pagination cuts at the limit) must
// not crash the layout.
let windowedGraph = CommitGraph(commits: [makeCommit("A", ["MISSING"]), makeCommit("B", ["MISSING"])])
expect(windowedGraph.rows.count == 2, "graph handles parents outside the loaded window")

// MARK: - GitExecutor (regression: process waiting must never wedge the chain)

// The app ignores SIGPIPE (GitalApp.init); the unconsumed-stdin test below
// writes into a closed pipe and needs the same protection here.
signal(SIGPIPE, SIG_IGN)

let executorTestsDone = DispatchSemaphore(value: 0)
Task {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("gital-executor-tests-\(getpid())")
    try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let executor = GitExecutor(workingDirectory: tempRoot)
    _ = try? await executor.run(["init"])

    // Launch failure (nonexistent cwd) must throw promptly, leave the
    // DispatchGroup balanced (unbalanced enters crash on dealloc), and not hang.
    let broken = GitExecutor(workingDirectory: URL(fileURLWithPath: "/nonexistent-gital-test-dir"))
    let launchFailed = (try? await broken.run(["version"])) == nil
    expect(launchFailed, "executor: launch failure throws instead of hanging")

    // A failing command (non-zero exit) must not stall the serialized chain.
    _ = try? await executor.run(["rev-parse", "no-such-ref"])
    let toplevel = (try? await executor.run(["rev-parse", "--show-toplevel"])) ?? ""
    expect(!toplevel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           "executor: chain survives a failing command")

    // stdin round-trip, and stdin that git exits without consuming.
    let hash = (try? await executor.run(["hash-object", "--stdin"], stdin: Data("hello\n".utf8))) ?? ""
    expect(hash.trimmingCharacters(in: .whitespacesAndNewlines).count == 40,
           "executor: stdin is delivered to git")
    let badSubcommand = (try? await executor.run(
        ["not-a-real-subcommand"], stdin: Data(repeating: 65, count: 1 << 20)
    )) == nil
    expect(badSubcommand, "executor: unconsumed stdin surfaces the error, no hang")

    // A background child inheriting the pipes (fsmonitor-daemon style) holds
    // EOF back after git exits; the drain grace cutoff must finish the
    // command with the output produced before exit instead of wedging.
    let leakStart = Date()
    let leaked = (try? await executor.run(
        ["-c", "alias.leak=!echo started; sleep 10 >/dev/null &", "leak"]
    )) ?? ""
    let leakElapsed = Date().timeIntervalSince(leakStart)
    expect(leaked.contains("started"), "executor: pre-exit output survives the drain cutoff")
    expect(leakElapsed < GitExecutor.drainGracePeriod + 5,
           "executor: orphaned pipe holder cannot wedge the chain (took \(String(format: "%.1f", leakElapsed))s)")
    let afterLeak = (try? await executor.run(["rev-parse", "--show-toplevel"])) != nil
    expect(afterLeak, "executor: chain keeps serving commands after the cutoff")

    // Hammer the chain with concurrent mixed success/failure commands; every
    // call must complete with the expected outcome.
    let outcomes = await withTaskGroup(of: Bool.self) { group -> [Bool] in
        for i in 0..<60 {
            group.addTask {
                if i % 5 == 0 {
                    return (try? await executor.run(["rev-parse", "bad-ref-\(i)"])) == nil
                }
                return (try? await executor.run(["rev-parse", "--show-toplevel"])) != nil
            }
        }
        var results: [Bool] = []
        for await outcome in group { results.append(outcome) }
        return results
    }
    expect(outcomes.count == 60 && outcomes.allSatisfy { $0 },
           "executor: 60 concurrent commands all complete correctly")

    executorTestsDone.signal()
}
if executorTestsDone.wait(timeout: .now() + 60) == .timedOut {
    failures += 1
    print("✗ executor tests timed out — process waiting hangs again")
}

// MARK: - GitHubAvatars

expect(GitHubAvatars.isGitHub(remoteURL: "https://github.com/k-ymmt/Gital.git"),
       "avatars: https github remote detected")
expect(GitHubAvatars.isGitHub(remoteURL: "git@github.com:k-ymmt/Gital.git"),
       "avatars: scp-like github remote detected")
expect(GitHubAvatars.isGitHub(remoteURL: "ssh://git@github.com/k-ymmt/Gital.git"),
       "avatars: ssh github remote detected")
expect(GitHubAvatars.isGitHub(remoteURL: "  https://GitHub.com/foo/bar.git\n"),
       "avatars: host match is case-insensitive and trims whitespace")
expect(!GitHubAvatars.isGitHub(remoteURL: "https://gitlab.com/foo/bar.git"),
       "avatars: non-github remote rejected")
expect(!GitHubAvatars.isGitHub(remoteURL: "git@gist.github.com:abc.git"),
       "avatars: github.com subdomain rejected")
expect(!GitHubAvatars.isGitHub(remoteURL: "/Users/me/repos/local"),
       "avatars: local path remote rejected")

expect(GitHubAvatars.url(login: "octocat", pixelSize: 64)?.absoluteString
        == "https://avatars.githubusercontent.com/octocat?s=64",
       "avatars: login URL")
expect(GitHubAvatars.url(login: "", pixelSize: 64) == nil,
       "avatars: empty login yields no URL")
expect(GitHubAvatars.url(email: "12345+octocat@users.noreply.github.com", pixelSize: 64)?.absoluteString
        == "https://avatars.githubusercontent.com/u/12345?s=64",
       "avatars: noreply email resolves by embedded user id")
expect(GitHubAvatars.url(email: "octocat@users.noreply.github.com", pixelSize: 64)?.absoluteString
        == "https://avatars.githubusercontent.com/octocat?s=64",
       "avatars: legacy noreply email resolves by login")
expect(GitHubAvatars.url(email: "u/583231@users.noreply.github.com", pixelSize: 64)?.absoluteString
        == "https://avatars.githubusercontent.com/u/e?email=u/583231@users.noreply.github.com&s=64",
       "avatars: crafted noreply local part cannot inject a URL path")
expect(GitHubAvatars.url(email: "dev@example.com", pixelSize: 64)?.absoluteString
        == "https://avatars.githubusercontent.com/u/e?email=dev@example.com&s=64",
       "avatars: plain email goes through the email endpoint")
expect(GitHubAvatars.url(email: "dev+tag@example.com", pixelSize: 64)?.absoluteString
        == "https://avatars.githubusercontent.com/u/e?email=dev%2Btag@example.com&s=64",
       "avatars: plus in email is percent-encoded")
expect(GitHubAvatars.url(email: "", pixelSize: 64) == nil,
       "avatars: empty email yields no URL")

// MARK: - PRViewedState

do {
    var state = PRViewedState()
    let files = ["a.swift", "b.swift", "c.swift"]

    // Commit-level viewed marks every file inside it viewed.
    state.setCommitViewed(true, hash: "abc1234")
    expect(state.isCommitViewed("abc1234"), "viewed: commit flag set")
    expect(state.isCommitFileViewed(commit: "abc1234", path: "a.swift"),
           "viewed: commit viewed implies its files viewed")
    expect(state.isCommitFileViewed(commit: "abc1234", path: "anything.txt"),
           "viewed: commit viewed covers files not yet enumerated")

    // Un-viewing one file demotes the commit but keeps the other files viewed.
    state.toggleCommitFile(commit: "abc1234", path: "b.swift", allPaths: files)
    expect(!state.isCommitViewed("abc1234"), "viewed: un-viewing a file demotes the commit")
    expect(!state.isCommitFileViewed(commit: "abc1234", path: "b.swift"),
           "viewed: the toggled file is no longer viewed")
    expect(state.isCommitFileViewed(commit: "abc1234", path: "a.swift")
            && state.isCommitFileViewed(commit: "abc1234", path: "c.swift"),
           "viewed: sibling files stay viewed after demotion")

    // Viewing the last remaining file promotes the commit.
    state.toggleCommitFile(commit: "abc1234", path: "b.swift", allPaths: files)
    expect(state.isCommitViewed("abc1234"), "viewed: last file viewed promotes the commit")
    expect(state.commitFiles["abc1234"] == nil, "viewed: promotion clears the per-file record")

    // Un-viewing the commit un-views all of its files.
    state.setCommitViewed(false, hash: "abc1234")
    expect(!state.isCommitFileViewed(commit: "abc1234", path: "a.swift"),
           "viewed: un-viewing the commit un-views its files")
    expect(state.isEmpty, "viewed: fully cleared state is empty")

    // Partial progress never promotes.
    state.toggleCommitFile(commit: "def5678", path: "a.swift", allPaths: files)
    expect(!state.isCommitViewed("def5678"), "viewed: partial progress does not promote")
    state.toggleCommitFile(commit: "def5678", path: "a.swift", allPaths: files)
    expect(state.isEmpty, "viewed: removing the only viewed file prunes the record")

    // PR-wide Files Changed flags are independent of commit flags.
    state.toggleFile("a.swift")
    expect(state.files.contains("a.swift"), "viewed: PR file toggles on")
    expect(!state.isCommitFileViewed(commit: "def5678", path: "a.swift"),
           "viewed: PR file flag is independent of commit flags")
    state.toggleFile("a.swift")
    expect(state.files.isEmpty, "viewed: PR file toggles off")
}

// MARK: - PRViewedStore

do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("gital-viewed-test-\(UUID().uuidString)")
    let file = dir.appendingPathComponent("pr-viewed.sqlite")
    defer { try? FileManager.default.removeItem(at: dir) }

    let repoA = URL(fileURLWithPath: "/repos/a")
    let repoB = URL(fileURLWithPath: "/repos/b")

    var stateA = PRViewedState()
    stateA.setCommitViewed(true, hash: "abc1234")
    stateA.toggleFile("a.swift")
    stateA.toggleCommitFile(commit: "0badf00", path: "p.swift", allPaths: ["p.swift", "q.swift"])
    PRViewedStore(repoRoot: repoA, databaseURL: file).save(stateA, for: 7)

    var stateB = PRViewedState()
    stateB.toggleCommitFile(commit: "def5678", path: "x.swift", allPaths: ["x.swift", "y.swift"])
    PRViewedStore(repoRoot: repoB, databaseURL: file).save(stateB, for: 3)
    // Same PR number as repo A's — must stay separate per repository.
    PRViewedStore(repoRoot: repoB, databaseURL: file).save(stateB, for: 7)

    let loadedA = PRViewedStore(repoRoot: repoA, databaseURL: file).load()
    expect(loadedA[7] == stateA, "store: state round-trips through disk")
    expect(loadedA.count == 1, "store: only own-repo rows load")
    expect(PRViewedStore(repoRoot: repoB, databaseURL: file).load()[3] == stateB,
           "store: repositories do not clobber each other")

    // Saving replaces the PR's previous rows instead of accumulating.
    stateA.toggleFile("a.swift")
    stateA.toggleFile("b.swift")
    let storeA = PRViewedStore(repoRoot: repoA, databaseURL: file)
    storeA.save(stateA, for: 7)
    expect(storeA.load()[7] == stateA, "store: re-saving a PR replaces its rows")

    storeA.save(PRViewedState(), for: 7)
    expect(storeA.load().isEmpty, "store: saving an empty state deletes the PR's rows")
    expect(PRViewedStore(repoRoot: repoB, databaseURL: file).load()[7] == stateB,
           "store: clearing one repo's PR keeps the other repo's same-numbered PR")
}

// MARK: - Result

print(failures == 0 ? "\nAll tests passed." : "\n\(failures) test(s) FAILED.")
exit(failures == 0 ? 0 : 1)
