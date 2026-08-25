import Foundation
import Testing

@testable import Gital

/// Reload semantics of `PullRequestsModel` around failure: a user-initiated
/// reload that cannot reach GitHub (offline, no remote) must keep the
/// stale-but-real data on screen instead of trading it for a spinner or
/// vanishing sidebar rows. The tests run against a temp repo with no GitHub
/// remote, so every gh call fails fast and locally.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PullRequestsModelReloadTests {
    /// Temp repo with one commit on `main` and no remotes; the model's gh
    /// and git network calls all fail deterministically.
    private func withModel(_ body: (PullRequestsModel) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gital-prs-reload-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let git = GitExecutor(workingDirectory: root)
        _ = try await git.run(["init", "-b", "main"])
        _ = try await git.run(["config", "user.name", "Gital Tests"])
        _ = try await git.run(["config", "user.email", "tests@example.com"])
        _ = try await git.run(["config", "commit.gpgsign", "false"])
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        _ = try await git.run(["add", "."])
        _ = try await git.run(["commit", "-m", "base"])

        let model = PullRequestsModel(
            repository: GitRepository(root: root),
            github: GitHubService(repoRoot: root)
        )
        try await body(model)
    }

    private func makeDetail(
        number: Int, commits: [PullRequestDetail.CommitInfo] = []
    ) -> PullRequestDetail {
        PullRequestDetail(
            number: number, title: "PR \(number)", author: "octocat",
            authorLogin: "octocat", state: "OPEN", isDraft: false,
            base: "main", head: "feature", createdAt: "2026-01-01T00:00:00Z",
            body: "", additions: 1, deletions: 0, changedFiles: 1,
            mergeable: "MERGEABLE", labels: [], reviewers: [],
            commits: commits,
            files: [.init(path: "file.txt", additions: 1, deletions: 0)]
        )
    }

    private func makeCommit(_ short: String) -> PullRequestDetail.CommitInfo {
        .init(hash: short, fullHash: short + String(repeating: "0", count: 33), message: "m", author: "octocat")
    }

    // MARK: - validatedItemSelection

    @Test func selectionOfStillListedCommitSurvivesValidation() {
        let detail = makeDetail(number: 1, commits: [makeCommit("abc1234")])
        let item = PullRequestsModel.ItemSelection.commit(hash: "abc1234")
        #expect(PullRequestsModel.validatedItemSelection(item, in: detail) == item)
    }

    @Test func selectionOfForcePushedAwayCommitIsCleared() {
        let detail = makeDetail(number: 1, commits: [makeCommit("def5678")])
        let item = PullRequestsModel.ItemSelection.commit(hash: "abc1234")
        #expect(PullRequestsModel.validatedItemSelection(item, in: detail) == nil)
    }

    @Test func fileSelectionPassesValidationUntouched() {
        // Files are not validated: a vanished file surfaces "no changes"
        // from the fresh diff fetch, unlike a commit that would silently
        // keep diffing from the local object store.
        let detail = makeDetail(number: 1)
        let item = PullRequestsModel.ItemSelection.file(path: "gone.txt")
        #expect(PullRequestsModel.validatedItemSelection(item, in: detail) == item)
    }

    @Test func nilSelectionPassesValidation() {
        #expect(PullRequestsModel.validatedItemSelection(nil, in: makeDetail(number: 1)) == nil)
    }

    // MARK: - reloadAll failure behavior

    @Test func failedReloadKeepsVisibleDetailAndSurfacesError() async throws {
        try await withModel { model in
            model.detailsCache[5] = makeDetail(number: 5, commits: [makeCommit("abc1234")])
            model.detailsCache[7] = makeDetail(number: 7)
            model.expanded = [5, 7]
            model.selectedNumber = 5
            await model.loadDetail()
            #expect(model.detail?.number == 5)

            await model.reloadAll()

            // The re-fetch failed: the stale detail must stay on screen
            // (not be swapped for an eternal spinner) with the failure
            // surfaced beside it.
            #expect(model.detail?.number == 5)
            #expect(model.detailLoadError != nil)
            // The expanded sidebar row's cache entry must survive the
            // failed refill instead of silently vanishing.
            #expect(model.detailsCache[7] != nil)
            #expect(model.detailsCache[5] != nil)
        }
    }

    @Test func reloadDropsCachedDetailsNothingIsShowing() async throws {
        try await withModel { model in
            model.detailsCache[5] = makeDetail(number: 5)
            model.detailsCache[9] = makeDetail(number: 9)
            model.selectedNumber = 5
            await model.loadDetail()

            await model.reloadAll()

            // PR 9 is neither selected nor expanded: its entry must not
            // survive a reload as a stale cache hit for the next click.
            #expect(model.detailsCache[9] == nil)
            #expect(model.detailsCache[5] != nil)
        }
    }

    @Test func reloadClearsSelectionOfCommitMissingFromCachedDetail() async throws {
        try await withModel { model in
            // The cached detail does not list the selected commit —
            // standing in for a refreshed detail after a force-push.
            model.detailsCache[5] = makeDetail(number: 5, commits: [makeCommit("def5678")])
            model.selectItem(.commit(hash: "abc1234"), in: 5)

            await model.reloadAll()

            #expect(model.selectedItem == nil)
        }
    }
}
