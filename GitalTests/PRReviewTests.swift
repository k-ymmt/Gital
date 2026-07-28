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

    @Test func reviewSubmissionBodyJSON() throws {
        let comments = [
            PendingReviewComment(
                anchor: ReviewCommentAnchor(path: "a.swift", side: .right, line: 12),
                body: "Nit: rename this"
            ),
            PendingReviewComment(
                anchor: ReviewCommentAnchor(path: "b.swift", side: .left, line: 3),
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
        #expect(sent[1]["side"] as? String == "LEFT", "old-side comments are sent as LEFT")
    }

    @Test func reviewSubmissionBodyOmitsEmptyFields() throws {
        let data = try GitHubService.reviewSubmissionBody(event: .approve, body: "   ", comments: [])
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["event"] as? String == "APPROVE", "bare approval still carries the event")
        #expect(json["body"] == nil, "blank summary is omitted, not sent as an empty string")
        #expect(json["comments"] == nil, "an empty comment list is omitted entirely")
    }
}
