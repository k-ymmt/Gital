import Foundation
import Testing
@testable import Gital

@MainActor
struct BranchTreeTests {
    private func names(_ rows: [BranchTreeRow<String>]) -> [String] {
        rows.map {
            switch $0 {
            case .folder(_, let name, _): "▸\(name)"
            case .leaf(_, let name, _, _): name
            }
        }
    }

    @Test func groupsSlashSeparatedNamesIntoFolders() {
        let rows = BranchTree.rows(
            [("feature/b", "feature/b"), ("feature/a", "feature/a"), ("main", "main")],
            keyPrefix: "branches",
            collapsed: []
        )
        #expect(names(rows) == ["▸feature", "a", "b", "main"], "folders first, leaves localized-sorted")
    }

    @Test func collapsedFolderHidesItsContents() {
        let rows = BranchTree.rows(
            [("feature/a", "feature/a"), ("main", "main")],
            keyPrefix: "branches",
            collapsed: ["branches/feature"]
        )
        #expect(names(rows) == ["▸feature", "main"], "collapsed folder keeps its row but drops children")
    }

    @Test func cacheReturnsSameRowsForUnchangedInputs() {
        let cache = BranchTreeRowsCache<String>()
        let items = [("feature/a", "feature/a"), ("main", "main")]
        let first = cache.rows(items, keyPrefix: "branches", collapsed: [])
        let second = cache.rows(items, keyPrefix: "branches", collapsed: [])
        #expect(first == second)
        #expect(second == BranchTree.rows(items, keyPrefix: "branches", collapsed: []),
                "cached result matches a fresh computation")
    }

    @Test func cacheInvalidatesWhenInputsChange() {
        let cache = BranchTreeRowsCache<String>()
        let items = [("feature/a", "feature/a"), ("main", "main")]
        _ = cache.rows(items, keyPrefix: "branches", collapsed: [])

        let collapsed = cache.rows(items, keyPrefix: "branches", collapsed: ["branches/feature"])
        #expect(names(collapsed) == ["▸feature", "main"], "collapse-state change recomputes")

        let grown = cache.rows(items + [("develop", "develop")], keyPrefix: "branches", collapsed: ["branches/feature"])
        #expect(names(grown) == ["▸feature", "develop", "main"], "item change recomputes")
    }

    @Test func cacheKeepsKeyPrefixesIndependent() {
        let cache = BranchTreeRowsCache<String>()
        let local = cache.rows([("main", "main")], keyPrefix: "branches", collapsed: [])
        let remote = cache.rows([("origin-main", "origin-main")], keyPrefix: "remote:origin", collapsed: [])
        #expect(names(local) == ["main"])
        #expect(names(remote) == ["origin-main"])
        #expect(cache.rows([("main", "main")], keyPrefix: "branches", collapsed: []) == local,
                "a different prefix never evicts another prefix's entry")
    }
}
