import Foundation
import Testing
@testable import Gital

@MainActor
struct PRViewedStateTests {
    @Test func commitAndFileFlags() {
        var state = PRViewedState()
        let files = ["a.swift", "b.swift", "c.swift"]

        // Commit-level viewed marks every file inside it viewed.
        state.setCommitViewed(true, hash: "abc1234")
        #expect(state.isCommitViewed("abc1234"), "commit flag set")
        #expect(state.isCommitFileViewed(commit: "abc1234", path: "a.swift"),
                "commit viewed implies its files viewed")
        #expect(state.isCommitFileViewed(commit: "abc1234", path: "anything.txt"),
                "commit viewed covers files not yet enumerated")

        // Un-viewing one file demotes the commit but keeps the other files viewed.
        state.toggleCommitFile(commit: "abc1234", path: "b.swift", allPaths: files)
        #expect(!state.isCommitViewed("abc1234"), "un-viewing a file demotes the commit")
        #expect(!state.isCommitFileViewed(commit: "abc1234", path: "b.swift"),
                "the toggled file is no longer viewed")
        #expect(state.isCommitFileViewed(commit: "abc1234", path: "a.swift")
                && state.isCommitFileViewed(commit: "abc1234", path: "c.swift"),
                "sibling files stay viewed after demotion")

        // Viewing the last remaining file promotes the commit.
        state.toggleCommitFile(commit: "abc1234", path: "b.swift", allPaths: files)
        #expect(state.isCommitViewed("abc1234"), "last file viewed promotes the commit")
        #expect(state.commitFiles["abc1234"] == nil, "promotion clears the per-file record")

        // Un-viewing the commit un-views all of its files.
        state.setCommitViewed(false, hash: "abc1234")
        #expect(!state.isCommitFileViewed(commit: "abc1234", path: "a.swift"),
                "un-viewing the commit un-views its files")
        #expect(state.isEmpty, "fully cleared state is empty")

        // Partial progress never promotes.
        state.toggleCommitFile(commit: "def5678", path: "a.swift", allPaths: files)
        #expect(!state.isCommitViewed("def5678"), "partial progress does not promote")
        state.toggleCommitFile(commit: "def5678", path: "a.swift", allPaths: files)
        #expect(state.isEmpty, "removing the only viewed file prunes the record")

        // PR-wide Files Changed flags are independent of commit flags.
        state.toggleFile("a.swift")
        #expect(state.files.contains("a.swift"), "PR file toggles on")
        #expect(!state.isCommitFileViewed(commit: "def5678", path: "a.swift"),
                "PR file flag is independent of commit flags")
        state.toggleFile("a.swift")
        #expect(state.files.isEmpty, "PR file toggles off")
    }

    // Demoting a single-file commit leaves nothing behind — an empty
    // per-file set would break isEmpty and linger as a phantom state.
    @Test func singleFileCommitDemotion() {
        var single = PRViewedState()
        single.setCommitViewed(true, hash: "aaa1111")
        single.toggleCommitFile(commit: "aaa1111", path: "only.swift", allPaths: ["only.swift"])
        #expect(!single.isCommitFileViewed(commit: "aaa1111", path: "only.swift"),
                "demoting a single-file commit un-views the file")
        #expect(single.isEmpty, "demoting a single-file commit clears the state")
    }
}

@MainActor
struct PRViewedStoreTests {
    @Test func persistenceAndIsolation() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gital-viewed-test-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("pr-viewed.sqlite")
        defer { try? FileManager.default.removeItem(at: dir) }

        let repoA = URL(fileURLWithPath: "/repos/a")
        let repoB = URL(fileURLWithPath: "/repos/b")

        let empty = PRViewedState()
        var stateA = PRViewedState()
        stateA.setCommitViewed(true, hash: "abc1234")
        stateA.toggleFile("a.swift")
        stateA.toggleCommitFile(commit: "0badf00", path: "p.swift", allPaths: ["p.swift", "q.swift"])
        PRViewedStore(repoRoot: repoA, databaseURL: file).apply(from: empty, to: stateA, for: 7)

        var stateB = PRViewedState()
        stateB.toggleCommitFile(commit: "def5678", path: "x.swift", allPaths: ["x.swift", "y.swift"])
        PRViewedStore(repoRoot: repoB, databaseURL: file).apply(from: empty, to: stateB, for: 3)
        // Same PR number as repo A's — must stay separate per repository.
        PRViewedStore(repoRoot: repoB, databaseURL: file).apply(from: empty, to: stateB, for: 7)

        let loadedA = PRViewedStore(repoRoot: repoA, databaseURL: file).load()
        #expect(loadedA[7] == stateA, "state round-trips through disk")
        #expect(loadedA.count == 1, "only own-repo rows load")
        #expect(PRViewedStore(repoRoot: repoB, databaseURL: file).load()[3] == stateB,
                "repositories do not clobber each other")

        // A mutation persists as a delta against the previous state.
        var stateA2 = stateA
        stateA2.toggleFile("a.swift")
        stateA2.toggleFile("b.swift")
        stateA2.setCommitViewed(false, hash: "abc1234")
        let storeA = PRViewedStore(repoRoot: repoA, databaseURL: file)
        storeA.apply(from: stateA, to: stateA2, for: 7)
        #expect(storeA.load()[7] == stateA2, "delta save applies removals and additions")

        // A second instance whose in-memory picture is stale only writes the
        // flags it touched — it must not wipe rows it never knew about.
        var stale = PRViewedState()
        stale.toggleFile("z.swift")
        PRViewedStore(repoRoot: repoA, databaseURL: file).apply(from: empty, to: stale, for: 7)
        var merged = stateA2
        merged.toggleFile("z.swift")
        #expect(storeA.load()[7] == merged, "stale-instance delta does not clobber other rows")

        // Re-inserting an already present flag (both instances viewed the same
        // file) must not abort the transaction.
        var reinsert = stale
        reinsert.toggleFile("b.swift")
        PRViewedStore(repoRoot: repoA, databaseURL: file).apply(from: stale, to: reinsert, for: 7)
        #expect(storeA.load()[7] == merged, "duplicate insert is absorbed, not fatal")

        storeA.apply(from: merged, to: empty, for: 7)
        #expect(storeA.load().isEmpty, "clearing a state deletes the PR's rows")
        #expect(PRViewedStore(repoRoot: repoB, databaseURL: file).load()[7] == stateB,
                "clearing one repo's PR keeps the other repo's same-numbered PR")
    }
}
