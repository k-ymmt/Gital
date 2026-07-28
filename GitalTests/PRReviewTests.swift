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
        #expect(sent[1]["side"] as? String == "LEFT", "old-side comments are sent as LEFT")
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
            7: [PendingReviewComment(
                anchor: ReviewCommentAnchor(path: "a.swift", side: .right, line: 12),
                lineText: "let x = 1",
                body: "draft body"
            )],
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
