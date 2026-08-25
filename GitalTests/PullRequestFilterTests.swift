import Foundation
import Testing
@testable import Gital

/// `StateFilter.matches` and the list filter (`filtered`) — pure logic that
/// decides which PRs the sidebar shows.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PullRequestFilterTests {
    private func pr(
        number: Int = 1, title: String = "Title", author: String = "alice",
        state: String = "OPEN", isDraft: Bool = false,
        head: String = "feature/x", reviewers: [String] = []
    ) -> PullRequestSummary {
        PullRequestSummary(
            number: number, title: title, author: author, state: state,
            isDraft: isDraft, headRefName: head, reviewRequestLogins: reviewers
        )
    }

    @Test func stateFilterMatching() {
        typealias Filter = PullRequestsModel.StateFilter
        let open = pr(state: "OPEN")
        let draft = pr(state: "OPEN", isDraft: true)
        let merged = pr(state: "MERGED")
        let closed = pr(state: "CLOSED")

        #expect(Filter.all.matches(closed, viewerLogin: nil))
        #expect(Filter.open.matches(open, viewerLogin: nil))
        #expect(Filter.open.matches(draft, viewerLogin: nil), "GitHub counts drafts as open")
        #expect(!Filter.open.matches(merged, viewerLogin: nil))
        #expect(Filter.draft.matches(draft, viewerLogin: nil))
        #expect(!Filter.draft.matches(open, viewerLogin: nil))
        #expect(Filter.merged.matches(merged, viewerLogin: nil) && !Filter.merged.matches(open, viewerLogin: nil))
        #expect(Filter.closed.matches(closed, viewerLogin: nil) && !Filter.closed.matches(merged, viewerLogin: nil))
    }

    @Test func awaitingYourReviewFilter() {
        typealias Filter = PullRequestsModel.StateFilter
        let requested = pr(state: "OPEN", reviewers: ["Reviewer"])
        #expect(Filter.awaitingYourReview.matches(requested, viewerLogin: "reviewer"),
                "login comparison ignores case")
        #expect(!Filter.awaitingYourReview.matches(requested, viewerLogin: "other"))
        #expect(!Filter.awaitingYourReview.matches(requested, viewerLogin: nil),
                "matches nothing until the viewer login loads")
        let closedButRequested = pr(state: "CLOSED", reviewers: ["reviewer"])
        #expect(!Filter.awaitingYourReview.matches(closedButRequested, viewerLogin: "reviewer"))
    }

    /// Runs `filtered` against a throwaway model (temp repo, gh calls never
    /// fire — the filter is pure over the injected list).
    private func withModel(_ body: (PullRequestsModel) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gital-pr-filter-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PullRequestsModel(
            repository: GitRepository(root: root),
            github: GitHubService(repoRoot: root)
        )
        try body(model)
    }

    @Test func filteredMatchesNumberTitleAuthorAndBranch() throws {
        try withModel { model in
            model.pullRequests = [
                pr(number: 12, title: "Fix crash", author: "alice", head: "fix/crash"),
                pr(number: 34, title: "Add feature", author: "bob", head: "feature/thing"),
            ]
            model.searchText = "#12"
            #expect(model.filtered.map(\.number) == [12], "# prefix matches the PR number")
            model.searchText = "１２"
            #expect(model.filtered.map(\.number) == [12], "full-width digits fold to a number")
            model.searchText = "bob"
            #expect(model.filtered.map(\.number) == [34], "author matches")
            model.searchText = "crash"
            #expect(model.filtered.map(\.number) == [12], "title and branch match")
            model.searchText = "nothing-here"
            #expect(model.filtered.isEmpty)
        }
    }

    @Test func filteredCombinesStateAndQuery() throws {
        try withModel { model in
            model.pullRequests = [
                pr(number: 1, title: "Open work", state: "OPEN"),
                pr(number: 2, title: "Merged work", state: "MERGED"),
            ]
            model.stateFilter = .merged
            model.searchText = "work"
            #expect(model.filtered.map(\.number) == [2], "state filter and query are ANDed")
            model.stateFilter = .all
            #expect(model.filtered.map(\.number) == [1, 2])
        }
    }
}
