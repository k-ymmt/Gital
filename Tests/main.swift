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
