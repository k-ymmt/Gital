import Foundation
import Testing
@testable import Gital

@MainActor
struct BranchDeleteConfirmationTests {
    private func branch(_ name: String, tip: String = "abc123") -> Branch {
        Branch(name: name, isCurrent: false, upstream: nil, tipHash: tip, upstreamRemote: nil)
    }

    private func pending(
        _ entries: [(String, Int?)],
        head: String? = "main"
    ) -> RepoViewModel.PendingBranchDelete {
        RepoViewModel.PendingBranchDelete(
            entries: entries.map { .init(branch: branch($0.0), unmergedCount: $0.1) },
            head: head
        )
    }

    // MARK: - Single branch (pre-existing wording must survive the multi rework)

    @Test func singleBranchTitleAndButton() {
        let p = pending([("feature", 0)])
        #expect(p.title == "Delete Branch?")
        #expect(p.confirmButtonLabel == "Delete")
    }

    @Test func singleBranchAllReachable() {
        #expect(pending([("feature", 0)]).message
            == "“feature” will be deleted. Its commits are all reachable from “main”.")
    }

    @Test func singleBranchUnmergedCommits() {
        let message = pending([("feature", 3)]).message
        #expect(message.contains("“feature” has 3 commit(s) not on “main”"))
        #expect(message.contains("This cannot be undone."))
    }

    @Test func singleBranchUnknownCountWarnsConservatively() {
        let message = pending([("feature", nil)]).message
        #expect(message.contains("could not be determined"))
        #expect(message.contains("This cannot be undone."))
    }

    @Test func singleBranchNilHeadFallsBackToHEAD() {
        #expect(pending([("feature", 0)], head: nil).message.contains("“HEAD”"))
    }

    // MARK: - Multiple branches

    @Test func multiBranchTitleAndButtonCarryTheCount() {
        let p = pending([("a", 0), ("b", 0), ("c", 0)])
        #expect(p.title == "Delete 3 Branches?")
        #expect(p.confirmButtonLabel == "Delete 3 Branches")
    }

    @Test func multiBranchAllReachableNamesEveryBranch() {
        let message = pending([("a", 0), ("b", 0)]).message
        #expect(message.contains("“a”, “b”"))
        #expect(message.contains("all reachable from “main”"))
    }

    @Test func multiBranchTotalsUnmergedCounts() {
        let message = pending([("a", 2), ("b", 0), ("c", 3)]).message
        #expect(message.contains("5 commit(s) not on “main”"))
        #expect(message.contains("This cannot be undone."))
    }

    // A single unknown count must poison the whole message — summing the
    // known counts would show a reassuring number exactly when part of the
    // selection is unaccounted for.
    @Test func multiBranchAnyUnknownCountWarnsConservatively() {
        let message = pending([("a", 0), ("b", nil), ("c", 4)]).message
        #expect(message.contains("could not be determined"))
        #expect(!message.contains("4 commit(s)"))
    }

    @Test func branchesAccessorPreservesOrder() {
        #expect(pending([("b", 0), ("a", 0)]).branches.map(\.name) == ["b", "a"])
    }
}
