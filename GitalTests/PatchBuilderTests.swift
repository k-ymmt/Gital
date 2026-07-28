import Foundation
import Testing
@testable import Gital

@MainActor
struct PatchBuilderTests {
    let diffs = DiffParser.parse(Fixtures.sampleDiff)
    let noNewline = DiffParser.parse(Fixtures.noNewlineDiff)

    @Test func hunkPatchRoundTrip() {
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
        #expect(rebuiltPatch == expectedPatch, "PatchBuilder round-trips a hunk")
    }

    // A file without a trailing newline must keep the "\ No newline" marker,
    // otherwise git apply rejects the rebuilt patch.
    @Test func noNewlineMarkersReEmitted() {
        let noNewlinePatch = PatchBuilder.hunkPatch(for: noNewline[0].hunks[0], in: noNewline[0])
        #expect(noNewlinePatch == Fixtures.noNewlineDiff.split(separator: "\n").dropFirst(2).joined(separator: "\n") + "\n",
                "PatchBuilder re-emits no-newline markers")
    }

    // Partial patches can't express renames or combined conflict hunks.
    @Test func refusesInexpressibleShapes() {
        let combined = DiffParser.parse(Fixtures.combinedDiff)
        #expect(PatchBuilder.hunkPatch(for: combined[0].hunks[0], in: combined[0]) == nil, "PatchBuilder refuses combined hunks")
        let renameWithHunk = FileDiff(path: "New.swift", oldPath: "Old.swift", isBinary: false, hunks: diffs[0].hunks)
        #expect(PatchBuilder.hunkPatch(for: diffs[0].hunks[0], in: renameWithHunk) == nil, "PatchBuilder refuses renames")
        let binaryWithHunk = FileDiff(path: "logo.png", oldPath: nil, isBinary: true, hunks: diffs[0].hunks)
        #expect(PatchBuilder.hunkPatch(for: diffs[0].hunks[0], in: binaryWithHunk) == nil, "PatchBuilder refuses binary files")
    }

    // Paths with characters that break the patch format get C-quoted like git does.
    @Test func quotesTrickyPaths() {
        let trickyDiff = FileDiff(path: "we\"ird.txt", oldPath: nil, isBinary: false, hunks: noNewline[0].hunks)
        #expect(PatchBuilder.hunkPatch(for: noNewline[0].hunks[0], in: trickyDiff)?.hasPrefix("--- \"a/we\\\"ird.txt\"\n") == true,
                "PatchBuilder quotes tricky paths")
    }

    // Staging one addition: the other addition is omitted (not in the index yet)
    // and the unpicked deletion becomes context (still in the index).
    @Test func stagesSingleAddition() throws {
        let guardLine = try #require(diffs[0].hunks[0].lines.first { $0.text.contains("guard") })
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
        #expect(stageOnePatch == expectedStageOne, "linesPatch stages a single addition")
    }

    // Unstaging one deletion: unpicked additions stay in the index as context.
    @Test func unstagesSingleDeletion() throws {
        let deletionLine = try #require(diffs[0].hunks[0].lines.first { $0.kind == .deletion })
        let unstageOnePatch = PatchBuilder.linesPatch(for: diffs[0], selecting: [deletionLine.id], direction: .unstage)
        #expect(unstageOnePatch?.contains("@@ -42,6 +42,5 @@") == true, "linesPatch recounts for unstage")
        #expect(unstageOnePatch?.contains("-        return !token.isEmpty") == true, "linesPatch keeps selected deletion")
        #expect(unstageOnePatch?.contains("\n+        guard") == false
                && unstageOnePatch?.contains("\n         guard !token.isEmpty else { return false }") == true,
                "linesPatch neutralizes unpicked additions into context")
    }

    // Discarding reuses the unstage shape (reverse-applied to the worktree instead
    // of the index): selecting one addition keeps the other addition as context and
    // omits the unpicked deletion, so only the picked line is reverted.
    @Test func discardsSingleAddition() throws {
        let countLine = try #require(diffs[0].hunks[0].lines.first { $0.text.contains("minTokenLength") })
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
        #expect(discardOnePatch == expectedDiscardOne, "linesPatch builds a single-addition discard patch")
    }

    // Hunks without any selected line are dropped from the patch.
    @Test func dropsUnselectedHunks() throws {
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
        let yLine = try #require(twoHunkDiff.hunks[1].lines.first { $0.text == "Y" })
        let secondHunkOnly = PatchBuilder.linesPatch(for: twoHunkDiff, selecting: [yLine.id], direction: .stage)
        #expect(secondHunkOnly?.contains("@@ -10,3 +10,4 @@") == true, "linesPatch recounts the selected hunk")
        #expect(secondHunkOnly?.contains("-b") == false && secondHunkOnly?.components(separatedBy: "@@ -").count == 2,
                "linesPatch drops unselected hunks")
    }

    // Selecting nothing applicable yields no patch.
    @Test func rejectsEmptySelections() throws {
        let contextLine = try #require(diffs[0].hunks[0].lines.first { $0.kind == .context })
        #expect(PatchBuilder.linesPatch(for: diffs[0], selecting: [contextLine.id], direction: .stage) == nil,
                "linesPatch ignores context-only selection")
        #expect(PatchBuilder.linesPatch(for: diffs[0], selecting: [], direction: .stage) == nil,
                "linesPatch rejects empty selection")
    }

    // Regression: staging every deletion line of a deleted file must produce a
    // deletion (`+++ /dev/null`), not an empty file staged under `b/path`.
    @Test func devNullPatchHeaders() {
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
        #expect(fullDeletePatch?.contains("+++ /dev/null") == true, "full deletion patch targets /dev/null")
        #expect(fullDeletePatch?.contains("--- a/del.txt") == true, "full deletion patch keeps the old path")

        let firstDeleteID = deletedFileDiff.hunks[0].lines[0].id
        let partialDeletePatch = PatchBuilder.linesPatch(for: deletedFileDiff, selecting: [firstDeleteID], direction: .stage)
        #expect(partialDeletePatch?.contains("+++ b/del.txt") == true, "partial deletion patch stays a modification")

        let untracked = DiffParser.parse(Fixtures.untrackedDiff)
        let untrackedIDs = Set(untracked[0].hunks[0].lines.map(\.id))
        let createPatch = PatchBuilder.linesPatch(for: untracked[0], selecting: untrackedIDs, direction: .stage)
        #expect(createPatch?.hasPrefix("--- /dev/null\n+++ b/new.txt\n") == true, "file creation patch sources /dev/null")
        #expect(PatchBuilder.hunkPatch(for: untracked[0].hunks[0], in: untracked[0])?.hasPrefix("--- /dev/null\n") == true,
                "hunkPatch sources /dev/null for creations")
    }

    // Regression: partial selections that would move a "\ No newline" marker
    // off the final line of its side cannot be expressed as a valid patch —
    // git apply would corrupt the target (concatenate lines) or reject the
    // patch. They must be refused instead of built wrong.
    @Test func noNewlineLineSelections() throws {
        let nnLines = noNewline[0].hunks[0].lines
        let nnDeletion = try #require(nnLines.first { $0.kind == .deletion })
        let nnAddition = try #require(nnLines.first { $0.kind == .addition })
        #expect(PatchBuilder.linesPatch(for: noNewline[0], selecting: [nnAddition.id], direction: .stage) == nil,
                "staging only the addition at a no-newline EOF is refused")
        #expect(PatchBuilder.linesPatch(for: noNewline[0], selecting: [nnDeletion.id], direction: .unstage) == nil,
                "discarding only the deletion at a no-newline EOF is refused")
        let nnDeleteOnly = PatchBuilder.linesPatch(for: noNewline[0], selecting: [nnDeletion.id], direction: .stage)
        #expect(nnDeleteOnly?.contains("-old last\n\\ No newline at end of file\n") == true,
                "staging only the deletion keeps a valid trailing marker")
        let nnBoth = PatchBuilder.linesPatch(for: noNewline[0], selecting: [nnDeletion.id, nnAddition.id], direction: .stage)
        #expect(nnBoth?.hasSuffix("+new last\n\\ No newline at end of file\n") == true,
                "full selection round-trips both markers")
    }
}
