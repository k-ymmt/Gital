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
    ["aaa111", "bbb222", "Kenji Mori", "kenji@aurora.app", "2 hours ago", "Polish welcome carousel", "HEAD -> feature/onboarding, origin/feature/onboarding"].joined(separator: "\u{1f}"),
    ["bbb222", "ccc333 ddd444", "Aiko Tanaka", "aiko@aurora.app", "Yesterday", "Merge branch 'main'", "tag: v1.2.0, main"].joined(separator: "\u{1f}"),
].joined(separator: "\u{1e}")

let commits = GitRepository.parseLog(logOutput)
expect(commits.count == 2, "log parses two commits")
expect(commits[0].refs.contains { $0.kind == .head && $0.name == "feature/onboarding" }, "log HEAD ref")
expect(commits[0].refs.contains { $0.kind == .remoteBranch && $0.name == "origin/feature/onboarding" }, "log remote ref")
expect(commits[1].parents == ["ccc333", "ddd444"], "log merge parents")
expect(commits[1].refs.contains { $0.kind == .tag && $0.name == "v1.2.0" }, "log tag ref")
expect(commits[1].refs.contains { $0.kind == .branch && $0.name == "main" }, "log branch ref")

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

// MARK: - Result

print(failures == 0 ? "\nAll tests passed." : "\n\(failures) test(s) FAILED.")
exit(failures == 0 ? 0 : 1)
