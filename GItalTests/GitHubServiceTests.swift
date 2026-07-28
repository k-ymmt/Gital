import Foundation
import Testing
@testable import Gital

@MainActor
struct GitHubServiceTests {
    @Test func pullRequestListParsing() throws {
        let prListJSON = Data("""
        [
          {"number": 12, "title": "Add feature", "author": {"login": "alice", "name": "Alice A"},
           "state": "OPEN", "isDraft": false, "headRefName": "feature/x",
           "reviewRequests": [{"login": "bob"}, {}]},
          {"number": 11, "title": "Old fix", "author": {"login": "carol", "name": ""},
           "state": "MERGED", "isDraft": false, "headRefName": "fix/y", "reviewRequests": null}
        ]
        """.utf8)
        let prs = try GitHubService.parsePullRequestList(prListJSON)
        #expect(prs.count == 2, "pr list parses two rows")
        #expect(prs[0].author == "Alice A", "pr author prefers display name")
        #expect(prs[0].reviewRequestLogins == ["bob"], "team review requests without login are dropped")
        #expect(prs[1].author == "carol", "empty display name falls back to login")

        #expect(throws: (any Error).self, "garbage pr list throws instead of decoding") {
            try GitHubService.parsePullRequestList(Data("not json".utf8))
        }
    }

    @Test func pullRequestDetailParsing() throws {
        let prDetailJSON = Data("""
        {"number": 12, "title": "Add feature", "author": {"login": "alice", "name": "Alice A"},
         "state": "OPEN", "isDraft": false, "baseRefName": "main", "headRefName": "feature/x",
         "createdAt": "2026-07-01T00:00:00Z", "body": "Hello", "additions": 10, "deletions": 2,
         "changedFiles": 1, "mergeable": "MERGEABLE", "labels": [{"name": "bug", "color": "ff0000"}],
         "latestReviews": [{"author": {"login": "bob", "name": null}, "state": "APPROVED"}],
         "reviewRequests": [{"login": "bob"}, {"login": "dave"}],
         "commits": [{"oid": "abcdef0123456789", "messageHeadline": "First", "authors": [{"name": "Alice A", "login": "alice"}]}],
         "files": [{"path": "a.swift", "additions": 10, "deletions": 2}]}
        """.utf8)
        let detail = try GitHubService.parsePullRequestDetail(prDetailJSON)
        #expect(detail.reviewers.count == 2, "reviewed reviewer is not duplicated by a pending request")
        #expect(detail.reviewers.contains { $0.name == "dave" && $0.state == "PENDING" }, "requested reviewer appears as pending")
        #expect(detail.commits.first?.hash == "abcdef0", "pr commit hash is truncated to 7 chars")
        #expect(detail.labels.first?.name == "bug", "pr labels decode")
    }
}
