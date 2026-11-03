import Foundation
import Testing
@testable import Gital

/// `ReviewSplitSegment.segments` — how a PR file's split-mode rows are cut
/// into web chunks so review cards render right below their anchored row.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ReviewSplitSegmentTests {
    private let diff = FileDiff(path: "f", oldPath: nil, isBinary: false, hunks: [
        DiffHunk(id: "f@h0", header: "@@ -10,3 +10,3 @@", oldStart: 10, newStart: 10, lines: [
            DiffLine(id: "f@0", kind: .context, text: "ctx", oldNumber: 10, newNumber: 10),
            DiffLine(id: "f@1", kind: .deletion, text: "old", oldNumber: 11, newNumber: nil),
            DiffLine(id: "f@2", kind: .addition, text: "new", oldNumber: nil, newNumber: 11),
            DiffLine(id: "f@3", kind: .context, text: "tail", oldNumber: 12, newNumber: 12),
        ]),
    ])

    private var rows: [SplitDiffRow] { SplitDiffRow.rows(for: diff.hunks) }

    private func draft(side: ReviewCommentAnchor.Side, line: Int, text: String) -> PendingReviewComment {
        PendingReviewComment(anchor: ReviewCommentAnchor(path: "f", side: side, line: line), lineText: text, body: "b")
    }

    private func thread(line: Int, text: String) -> ReviewThread {
        ReviewThread(
            id: "t", path: "f", side: .right, line: line, lineText: text,
            isResolved: false, isOutdated: false,
            comments: [.init(id: 1, authorLogin: "alice", body: "hi", createdAt: "now")],
            hasMoreComments: false
        )
    }

    @Test func withoutCardsTheFileIsOneChunk() {
        let segments = ReviewSplitSegment.segments(for: diff, threads: [], comments: [])
        #expect(segments.count == 1)
        #expect(segments[0].rows.map(\.id) == rows.map(\.id))
        #expect(segments[0].id == "\(rows[0].id)→end")
    }

    @Test func chunkEndsAtTheRowCarryingACard() {
        let comment = draft(side: .left, line: 11, text: "old")
        let segments = ReviewSplitSegment.segments(for: diff, threads: [], comments: [comment])
        // Header, context, and the paired deletion/addition row end the
        // first chunk; the trailing context row is the remainder.
        #expect(segments.count == 2)
        #expect(segments[0].rows.map(\.id) == rows[0...2].map(\.id))
        #expect(segments[0].id == "\(rows[0].id)→\(rows[2].id)")
        #expect(segments[0].comments == [comment])
        #expect(segments[0].threads.isEmpty)
        #expect(segments[1].id == "\(rows[3].id)→end")
    }

    @Test func threadsAndDraftsShareTheAnchoringRule() {
        let segments = ReviewSplitSegment.segments(
            for: diff,
            threads: [thread(line: 12, text: "tail"), thread(line: 12, text: "mismatch")],
            comments: []
        )
        #expect(segments.count == 1, "the anchored row is the last one, so nothing remains")
        #expect(segments[0].threads.map(\.lineText) == ["tail"], "content mismatch vetoes the coordinate match")
        #expect(segments[0].id == "\(rows[0].id)→\(rows[3].id)")
    }
}
