import Foundation
import Testing
@testable import Gital

/// Split rows anchor review cards through `SplitDiffRow.anchorableLines` +
/// the same `isAnchored` rule the unified pane uses. These pin the column
/// semantics the old hand-rolled matcher encoded: deletions live on the
/// left column, additions and context on the right, and a left context
/// side (whose number is an OLD number) must never satisfy a RIGHT anchor.
@MainActor
struct SplitRowAnchoringTests {
    private let lines = [
        DiffLine(id: "f@0", kind: .context, text: "ctx", oldNumber: 10, newNumber: 10),
        DiffLine(id: "f@1", kind: .deletion, text: "old", oldNumber: 11, newNumber: nil),
        DiffLine(id: "f@2", kind: .addition, text: "new", oldNumber: nil, newNumber: 11),
    ]

    private func contentRows() -> [SplitDiffRow] {
        let hunk = DiffHunk(id: "f@h0", header: "@@ -10,2 +10,2 @@", oldStart: 10, newStart: 10, lines: lines)
        return SplitDiffRow.rows(for: [hunk]).filter { !$0.isHunkHeader }
    }

    private func draft(side: ReviewCommentAnchor.Side, line: Int, text: String) -> PendingReviewComment {
        PendingReviewComment(anchor: ReviewCommentAnchor(path: "f", side: side, line: line), lineText: text, body: "b")
    }

    private func matches(_ comment: PendingReviewComment, _ row: SplitDiffRow) -> Bool {
        row.anchorableLines.contains { comment.isAnchored(to: $0, path: "f") }
    }

    @Test func columnsAnchorLikeTheUnifiedRule() {
        let rows = contentRows()
        #expect(rows.count == 2, "context row + paired deletion/addition row")

        let deletion = draft(side: .left, line: 11, text: "old")
        let addition = draft(side: .right, line: 11, text: "new")
        let context = draft(side: .right, line: 10, text: "ctx")

        #expect(matches(context, rows[0]) && !matches(deletion, rows[0]) && !matches(addition, rows[0]))
        #expect(matches(deletion, rows[1]) && matches(addition, rows[1]) && !matches(context, rows[1]))
    }

    // The left context side carries OLD number 10; a RIGHT anchor at line 10
    // must match through the RIGHT side only — if left sides ever leak a new
    // number, a right anchor could land on an unrelated row.
    @Test func leftContextSideNeverSatisfiesARightAnchor() {
        let shifted = [DiffLine(id: "g@0", kind: .context, text: "ctx", oldNumber: 10, newNumber: 20)]
        let hunk = DiffHunk(id: "g@h0", header: "@@ -10 +20 @@", oldStart: 10, newStart: 20, lines: shifted)
        let row = SplitDiffRow.rows(for: [hunk]).filter { !$0.isHunkHeader }[0]
        let atOldNumber = PendingReviewComment(
            anchor: ReviewCommentAnchor(path: "g", side: .right, line: 10), lineText: "ctx", body: "b"
        )
        let atNewNumber = PendingReviewComment(
            anchor: ReviewCommentAnchor(path: "g", side: .right, line: 20), lineText: "ctx", body: "b"
        )
        #expect(!row.anchorableLines.contains { atOldNumber.isAnchored(to: $0, path: "g") })
        #expect(row.anchorableLines.contains { atNewNumber.isAnchored(to: $0, path: "g") })
    }

    @Test func contentMismatchVetoesACoordinateMatch() {
        let rows = contentRows()
        let wrongText = draft(side: .left, line: 11, text: "different")
        #expect(!matches(wrongText, rows[1]))
    }
}
