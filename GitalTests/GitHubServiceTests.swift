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

    // A re-requested reviewer's review row carries their display name while
    // the request carries the login — matching must happen on login, and the
    // fresh request demotes the stale review state back to pending.
    @Test func reRequestedReviewerIsNotDuplicated() throws {
        let json = Data("""
        {"number": 1, "title": "T", "author": {"login": "alice", "name": null},
         "state": "OPEN", "isDraft": false, "baseRefName": "main", "headRefName": "b",
         "createdAt": "2026-07-01T00:00:00Z", "body": "", "additions": 0, "deletions": 0,
         "changedFiles": 0, "mergeable": "MERGEABLE", "labels": [],
         "latestReviews": [
           {"author": {"login": "bob", "name": "Bob B"}, "state": "APPROVED"},
           {"author": null, "state": "COMMENTED"},
           {"author": null, "state": "COMMENTED"}
         ],
         "reviewRequests": [{"login": "bob"}],
         "commits": [], "files": []}
        """.utf8)
        let detail = try GitHubService.parsePullRequestDetail(json)
        let bobs = detail.reviewers.filter { $0.login == "bob" }
        #expect(bobs.count == 1, "re-requested reviewer appears once")
        #expect(bobs.first?.state == "PENDING", "re-request outranks the stale review state")
        #expect(bobs.first?.name == "Bob B", "display name is kept")
        let ids = detail.reviewers.map(\.id)
        #expect(Set(ids).count == ids.count, "ghost (nil-author) reviewers still get unique row ids")
    }

    @Test func mergePullRequestLists() {
        func pr(_ number: Int, state: String) -> PullRequestSummary {
            PullRequestSummary(number: number, title: "PR \(number)", author: "a", state: state,
                               isDraft: false, headRefName: "b\(number)", reviewRequestLogins: [])
        }
        let merged = GitHubService.mergePullRequestLists(
            open: [pr(12, state: "OPEN"), pr(3, state: "OPEN")],
            recent: [pr(12, state: "OPEN"), pr(11, state: "MERGED")]
        )
        #expect(merged.map(\.number) == [12, 11, 3], "windows merge de-duplicated, newest first")
    }
}
