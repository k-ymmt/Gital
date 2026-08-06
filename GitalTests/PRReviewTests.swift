import Foundation
import Testing
@testable import Gital

@MainActor
struct PRReviewTests {
    @Test func anchorDerivation() {
        let addition = DiffLine(id: "a.swift@0", kind: .addition, text: "new", oldNumber: nil, newNumber: 12)
        let deletion = DiffLine(id: "a.swift@1", kind: .deletion, text: "old", oldNumber: 7, newNumber: nil)
        let context = DiffLine(id: "a.swift@2", kind: .context, text: "ctx", oldNumber: 8, newNumber: 13)

        let additionAnchor = ReviewCommentAnchor(path: "a.swift", diffLine: addition)
        #expect(additionAnchor == ReviewCommentAnchor(path: "a.swift", side: .right, line: 12),
                "additions anchor to the new side")

        let deletionAnchor = ReviewCommentAnchor(path: "a.swift", diffLine: deletion)
        #expect(deletionAnchor == ReviewCommentAnchor(path: "a.swift", side: .left, line: 7),
                "deletions anchor to the old side")

        let contextAnchor = ReviewCommentAnchor(path: "a.swift", diffLine: context)
        #expect(contextAnchor == ReviewCommentAnchor(path: "a.swift", side: .right, line: 13),
                "context lines anchor to the new side")
    }

    @Test func anchorMatching() {
        // Same coordinates parsed from a different diff (commit view vs the
        // whole-PR diff) get different DiffLine IDs; matching goes by
        // side + number so the comment surfaces in both.
        let anchor = ReviewCommentAnchor(path: "a.swift", side: .right, line: 12)
        let sameLineOtherParse = DiffLine(id: "a.swift@99", kind: .addition, text: "new", oldNumber: nil, newNumber: 12)
        #expect(anchor.matches(sameLineOtherParse), "right anchor matches the addition at its line")

        let context = DiffLine(id: "a.swift@3", kind: .context, text: "ctx", oldNumber: 12, newNumber: 12)
        let deletion = DiffLine(id: "a.swift@4", kind: .deletion, text: "old", oldNumber: 12, newNumber: nil)
        #expect(anchor.matches(context), "right anchor matches a context line by new number")
        #expect(!anchor.matches(deletion), "right anchor never matches a deletion")

        let leftAnchor = ReviewCommentAnchor(path: "a.swift", side: .left, line: 12)
        #expect(leftAnchor.matches(deletion), "left anchor matches the deletion by old number")
        #expect(!leftAnchor.matches(context), "left anchor only matches deletions")
    }

    @Test func displayAnchoringRequiresMatchingContent() {
        let comment = PendingReviewComment(
            anchor: ReviewCommentAnchor(path: "a.swift", side: .right, line: 12),
            lineText: "let x = 1",
            body: "why?"
        )
        let sameLine = DiffLine(id: "a.swift@0", kind: .addition, text: "let x = 1", oldNumber: nil, newNumber: 12)
        let sameNumberOtherContent = DiffLine(id: "a.swift@1", kind: .addition, text: "unrelated", oldNumber: nil, newNumber: 12)

        #expect(comment.isAnchored(to: sameLine, path: "a.swift"), "comment hangs under its own line")
        #expect(!comment.isAnchored(to: sameNumberOtherContent, path: "a.swift"),
                "a same-numbered line with different content (another commit's diff) does not attract the comment")
        #expect(!comment.isAnchored(to: sameLine, path: "b.swift"), "path must match")
    }

    @Test func submitAnchorResolution() {
        // Whole-PR diff: "let x = 1" sits at RIGHT:45 (a later commit
        // inserted lines above the region the draft was written on).
        let prDiff = [FileDiff(
            path: "a.swift",
            oldPath: nil,
            isBinary: false,
            hunks: [DiffHunk(id: "a.swift@0", header: "@@ -40,3 +40,4 @@", oldStart: 40, newStart: 40, lines: [
                DiffLine(id: "a.swift@0", kind: .context, text: "ctx", oldNumber: 40, newNumber: 44),
                DiffLine(id: "a.swift@1", kind: .addition, text: "let x = 1", oldNumber: nil, newNumber: 45),
                DiffLine(id: "a.swift@2", kind: .deletion, text: "removed", oldNumber: 41, newNumber: nil),
            ])]
        )]

        let exact = PendingReviewComment(
            anchor: ReviewCommentAnchor(path: "a.swift", side: .right, line: 45),
            lineText: "let x = 1", body: "b"
        )
        #expect(exact.resolvedAnchor(in: prDiff) == exact.anchor,
                "a draft already in PR coordinates resolves to itself")

        let shifted = PendingReviewComment(
            anchor: ReviewCommentAnchor(path: "a.swift", side: .right, line: 40),
            lineText: "let x = 1", body: "b"
        )
        #expect(shifted.resolvedAnchor(in: prDiff) == ReviewCommentAnchor(path: "a.swift", side: .right, line: 45),
                "a commit-diff draft re-anchors to the PR-diff line with the same content")

        let vanished = PendingReviewComment(
            anchor: ReviewCommentAnchor(path: "a.swift", side: .right, line: 40),
            lineText: "overwritten by a later commit", body: "b"
        )
        #expect(vanished.resolvedAnchor(in: prDiff) == nil,
                "a draft whose line is gone from the PR diff fails resolution instead of landing on the wrong line")

        let wrongSide = PendingReviewComment(
            anchor: ReviewCommentAnchor(path: "a.swift", side: .left, line: 40),
            lineText: "let x = 1", body: "b"
        )
        #expect(wrongSide.resolvedAnchor(in: prDiff) == nil,
                "left-side drafts only re-anchor to deletions")

        let otherFile = PendingReviewComment(
            anchor: ReviewCommentAnchor(path: "renamed.swift", side: .right, line: 45),
            lineText: "let x = 1", body: "b"
        )
        #expect(otherFile.resolvedAnchor(in: prDiff) == nil,
                "a path absent from the PR diff (rename) fails resolution")

        let ambiguousDiff = [FileDiff(
            path: "a.swift", oldPath: nil, isBinary: false,
            hunks: [DiffHunk(id: "a.swift@0", header: "@@", oldStart: 1, newStart: 1, lines: [
                DiffLine(id: "a.swift@0", kind: .addition, text: "dup", oldNumber: nil, newNumber: 5),
                DiffLine(id: "a.swift@1", kind: .addition, text: "dup", oldNumber: nil, newNumber: 9),
            ])]
        )]
        let ambiguous = PendingReviewComment(
            anchor: ReviewCommentAnchor(path: "a.swift", side: .right, line: 3),
            lineText: "dup", body: "b"
        )
        #expect(ambiguous.resolvedAnchor(in: ambiguousDiff) == nil,
                "content appearing on several lines cannot be re-anchored unambiguously")
    }

    @Test func submitRangeResolution() {
        let prDiff = [FileDiff(
            path: "a.swift",
            oldPath: nil,
            isBinary: false,
            hunks: [
                DiffHunk(id: "a.swift@0", header: "@@ -40,3 +40,4 @@", oldStart: 40, newStart: 40, lines: [
                    DiffLine(id: "a.swift@0", kind: .context, text: "ctx", oldNumber: 40, newNumber: 44),
                    DiffLine(id: "a.swift@1", kind: .addition, text: "let x = 1", oldNumber: nil, newNumber: 45),
                    DiffLine(id: "a.swift@2", kind: .deletion, text: "removed", oldNumber: 41, newNumber: nil),
                ]),
                DiffHunk(id: "a.swift@1", header: "@@ -60,2 +64,3 @@", oldStart: 60, newStart: 64, lines: [
                    DiffLine(id: "a.swift@3", kind: .context, text: "later ctx", oldNumber: 60, newNumber: 64),
                    DiffLine(id: "a.swift@4", kind: .addition, text: "let y = 2", oldNumber: nil, newNumber: 65),
                ]),
            ]
        )]

        let exact = PendingReviewComment(
            anchor: ReviewCommentAnchor(path: "a.swift", side: .right, line: 45),
            lineText: "let x = 1",
            startAnchor: ReviewCommentAnchor(path: "a.swift", side: .right, line: 44),
            startLineText: "ctx",
            body: "b"
        )
        #expect(exact.resolved(in: prDiff) == exact,
                "a range draft already in PR coordinates resolves to itself, id and range intact")

        let shifted = PendingReviewComment(
            anchor: ReviewCommentAnchor(path: "a.swift", side: .right, line: 41),
            lineText: "let x = 1",
            startAnchor: ReviewCommentAnchor(path: "a.swift", side: .right, line: 40),
            startLineText: "ctx",
            body: "b"
        )
        let resolvedShifted = shifted.resolved(in: prDiff)
        #expect(resolvedShifted?.anchor == ReviewCommentAnchor(path: "a.swift", side: .right, line: 45)
                && resolvedShifted?.startAnchor == ReviewCommentAnchor(path: "a.swift", side: .right, line: 44),
                "both ends of a commit-diff range re-anchor to the PR-diff lines with the same content")

        let inverted = PendingReviewComment(
            anchor: ReviewCommentAnchor(path: "a.swift", side: .right, line: 44),
            lineText: "ctx",
            startAnchor: ReviewCommentAnchor(path: "a.swift", side: .right, line: 45),
            startLineText: "let x = 1",
            body: "b"
        )
        #expect(inverted.resolved(in: prDiff) == nil,
                "a range whose resolved start no longer precedes its end fails instead of sending an inverted range")

        let vanishedStart = PendingReviewComment(
            anchor: ReviewCommentAnchor(path: "a.swift", side: .right, line: 45),
            lineText: "let x = 1",
            startAnchor: ReviewCommentAnchor(path: "a.swift", side: .right, line: 40),
            startLineText: "overwritten by a later commit",
            body: "b"
        )
        #expect(vanishedStart.resolved(in: prDiff) == nil,
                "a range whose start line is gone from the PR diff fails resolution")

        // GitHub rejects ranges whose ends sit in different hunks — a range
        // drafted as one contiguous hunk on a commit diff can straddle a
        // hunk boundary of the whole-PR diff, so resolution must catch it
        // here instead of letting the whole submission 422.
        let crossHunk = PendingReviewComment(
            anchor: ReviewCommentAnchor(path: "a.swift", side: .right, line: 65),
            lineText: "let y = 2",
            startAnchor: ReviewCommentAnchor(path: "a.swift", side: .right, line: 45),
            startLineText: "let x = 1",
            body: "b"
        )
        #expect(crossHunk.resolved(in: prDiff) == nil,
                "a range spanning two hunks of the PR diff fails resolution instead of poisoning the submission")

        let singleLine = PendingReviewComment(
            anchor: ReviewCommentAnchor(path: "a.swift", side: .right, line: 45),
            lineText: "let x = 1",
            body: "b"
        )
        #expect(singleLine.resolved(in: prDiff)?.startAnchor == nil,
                "a single-line draft stays single-line through resolution")
    }

    // A draft card's range label pairs the start's drafting-time number with
    // the displayed diff — legitimate only when that diff actually has the
    // start line at those coordinates. On a differently-numbered diff
    // (commit vs whole-PR) the label falls back to the end line the card
    // hangs under instead of mixing two coordinate systems.
    @Test func rangeLabelFallsBackWhenStartMissesTheDisplayedDiff() {
        let diff = FileDiff(
            path: "a.swift",
            oldPath: nil,
            isBinary: false,
            hunks: [DiffHunk(id: "a.swift@0", header: "@@", oldStart: 40, newStart: 44, lines: [
                DiffLine(id: "a.swift@0", kind: .context, text: "ctx", oldNumber: 40, newNumber: 44),
                DiffLine(id: "a.swift@1", kind: .addition, text: "let x = 1", oldNumber: nil, newNumber: 45),
            ])]
        )

        let matching = PendingReviewComment(
            anchor: ReviewCommentAnchor(path: "a.swift", side: .right, line: 45),
            lineText: "let x = 1",
            startAnchor: ReviewCommentAnchor(path: "a.swift", side: .right, line: 44),
            startLineText: "ctx",
            body: "b"
        )
        #expect(pendingCommentLineLabel(for: matching, in: diff) == "Lines 44–45",
                "a start present in the displayed diff labels the full range")

        let foreignStart = PendingReviewComment(
            anchor: ReviewCommentAnchor(path: "a.swift", side: .right, line: 45),
            lineText: "let x = 1",
            startAnchor: ReviewCommentAnchor(path: "a.swift", side: .right, line: 40),
            startLineText: "ctx",
            body: "b"
        )
        #expect(pendingCommentLineLabel(for: foreignStart, in: diff) == "Line 45",
                "a start numbered by another diff falls back to the end line")

        let single = PendingReviewComment(
            anchor: ReviewCommentAnchor(path: "a.swift", side: .left, line: 40),
            lineText: "ctx",
            body: "b"
        )
        #expect(pendingCommentLineLabel(for: single, in: diff) == "Line 40 (old)",
                "single-line drafts keep the plain line label")
    }

    // Old and new line numbers aren't comparable, so a range crossing sides
    // (e.g. new 44 down to old 41) must name each end's side — a bare
    // "44–41" reads as an inverted range anchored on the wrong lines.
    @Test func rangeLabelsMarkBothSidesWhenMixed() {
        let right40 = ReviewCommentAnchor(path: "a.swift", side: .right, line: 40)
        let right44 = ReviewCommentAnchor(path: "a.swift", side: .right, line: 44)
        #expect(reviewRangeText(start: right40, end: right44) == "40–44",
                "same-side new ranges carry no side markers")

        let left39 = ReviewCommentAnchor(path: "a.swift", side: .left, line: 39)
        let left41 = ReviewCommentAnchor(path: "a.swift", side: .left, line: 41)
        #expect(reviewRangeText(start: left39, end: left41) == "39–41 (old)",
                "same-side old ranges mark the side once")

        #expect(reviewRangeText(start: right44, end: left41) == "44 (new)–41 (old)",
                "cross-side ranges mark both ends so the numbers can't read as inverted")
    }

    @Test func draftsSavedBeforeRangesStillDecode() throws {
        let json = Data("""
        {"id":"00000000-0000-0000-0000-000000000000","anchor":{"path":"a.swift","side":"RIGHT","line":12},"lineText":"let x = 1","body":"draft"}
        """.utf8)
        let comment = try JSONDecoder().decode(PendingReviewComment.self, from: json)
        #expect(comment.startAnchor == nil && comment.startLineText == nil,
                "drafts persisted before ranges existed decode as single-line comments")
        #expect(comment.anchor.line == 12 && comment.body == "draft", "the rest of the draft survives")
    }

    @Test func reviewSubmissionBodyJSON() throws {
        let comments = [
            PendingReviewComment(
                anchor: ReviewCommentAnchor(path: "a.swift", side: .right, line: 12),
                lineText: "let x = 1",
                body: "Nit: rename this"
            ),
            PendingReviewComment(
                anchor: ReviewCommentAnchor(path: "b.swift", side: .left, line: 3),
                lineText: "old line",
                body: "Why was this removed?"
            ),
        ]
        let data = try GitHubService.reviewSubmissionBody(event: .requestChanges, body: "  Overall notes  ", comments: comments)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["event"] as? String == "REQUEST_CHANGES", "event uses the API spelling")
        #expect(json["body"] as? String == "Overall notes", "summary body is trimmed")
        let sent = try #require(json["comments"] as? [[String: Any]])
        #expect(sent.count == 2, "every draft comment is included")
        #expect(sent[0]["path"] as? String == "a.swift" && sent[0]["side"] as? String == "RIGHT"
                && sent[0]["line"] as? Int == 12 && sent[0]["body"] as? String == "Nit: rename this",
                "comment payload carries path, side, line, and body")
        #expect(sent[0]["lineText"] == nil, "the local lineText bookkeeping never reaches the API")
        #expect(sent[0]["start_line"] == nil && sent[0]["start_side"] == nil,
                "single-line comments omit the range-start fields entirely")
        #expect(sent[1]["side"] as? String == "LEFT", "old-side comments are sent as LEFT")
    }

    @Test func reviewSubmissionBodyMultiLineJSON() throws {
        let comments = [
            PendingReviewComment(
                anchor: ReviewCommentAnchor(path: "a.swift", side: .right, line: 12),
                lineText: "let x = 1",
                startAnchor: ReviewCommentAnchor(path: "a.swift", side: .right, line: 9),
                startLineText: "let start = 0",
                body: "Range comment"
            ),
        ]
        let data = try GitHubService.reviewSubmissionBody(event: .comment, body: "sum", comments: comments)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sent = try #require(json["comments"] as? [[String: Any]])
        #expect(sent[0]["start_line"] as? Int == 9 && sent[0]["start_side"] as? String == "RIGHT",
                "multi-line comments carry the range start in the API's snake_case spelling")
        #expect(sent[0]["line"] as? Int == 12 && sent[0]["side"] as? String == "RIGHT",
                "the range's last line stays the main line/side pair")
        #expect(sent[0]["startLineText"] == nil, "the local start-line bookkeeping never reaches the API")
    }

    @Test func reviewSubmissionBodyOmitsEmptyFields() throws {
        let data = try GitHubService.reviewSubmissionBody(event: .approve, body: "   ", comments: [])
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["event"] as? String == "APPROVE", "bare approval still carries the event")
        #expect(json["body"] == nil, "blank summary is omitted, not sent as an empty string")
        #expect(json["comments"] == nil, "an empty comment list is omitted entirely")
    }

    @Test func pendingReviewStoreRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PRReviewTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("drafts.json")
        let repoRoot = URL(fileURLWithPath: "/tmp/repo")

        let drafts: [Int: [PendingReviewComment]] = [
            7: [
                PendingReviewComment(
                    anchor: ReviewCommentAnchor(path: "a.swift", side: .right, line: 12),
                    lineText: "let x = 1",
                    body: "draft body"
                ),
                PendingReviewComment(
                    anchor: ReviewCommentAnchor(path: "a.swift", side: .right, line: 20),
                    lineText: "end line",
                    startAnchor: ReviewCommentAnchor(path: "a.swift", side: .right, line: 18),
                    startLineText: "start line",
                    body: "range draft"
                ),
            ],
        ]
        let store = PendingReviewStore(repoRoot: repoRoot, fileURL: fileURL)
        store.save(drafts)

        let reloaded = PendingReviewStore(repoRoot: repoRoot, fileURL: fileURL).load()
        #expect(reloaded == drafts, "drafts survive a save/load round trip, ids and anchors intact")

        store.save([:])
        #expect(!FileManager.default.fileExists(atPath: fileURL.path),
                "an emptied draft map removes the file instead of leaving a stale one")
        #expect(PendingReviewStore(repoRoot: repoRoot, fileURL: fileURL).load().isEmpty,
                "a missing file loads as no drafts")
    }
}
