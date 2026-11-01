import Foundation
import Testing
@testable import Gital

/// `BranchFilter` — the pure logic behind the Branches-tab search field.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BranchFilterTests {
    private func branch(_ name: String, current: Bool = false) -> Branch {
        Branch(name: name, isCurrent: current, upstream: nil, tipHash: "abc1234", upstreamRemote: nil)
    }

    private let branches = [
        Branch(name: "main", isCurrent: true, upstream: "origin/main", tipHash: "1", upstreamRemote: "origin"),
        Branch(name: "feature/login-page", isCurrent: false, upstream: nil, tipHash: "2", upstreamRemote: nil),
        Branch(name: "feature/Search", isCurrent: false, upstream: nil, tipHash: "3", upstreamRemote: nil),
        Branch(name: "fix/typo", isCurrent: false, upstream: nil, tipHash: "4", upstreamRemote: nil),
    ]
    private let remotes = [
        RemoteInfo(name: "origin", branches: ["main", "feature/login-page"]),
        RemoteInfo(name: "upstream", branches: ["main", "release/2.0"]),
    ]
    private let tags = [Tag(name: "v1.0.0", tipHash: "1"), Tag(name: "v2.0.0-rc1", tipHash: "2")]

    @Test func emptyOrWhitespaceQueryIsInactiveAndKeepsEverything() {
        #expect(!BranchFilter.isActive(""))
        #expect(!BranchFilter.isActive("   \n"))
        #expect(BranchFilter.branches(branches, query: "  ") == branches)
        #expect(BranchFilter.remotes(remotes, query: "") == remotes)
        #expect(BranchFilter.tags(tags, query: "\t") == tags)
    }

    @Test func matchesSubstringOfFullNameCaseInsensitively() {
        #expect(BranchFilter.branches(branches, query: "feat").map(\.name) == ["feature/login-page", "feature/Search"])
        #expect(BranchFilter.branches(branches, query: "SEARCH").map(\.name) == ["feature/Search"])
        #expect(BranchFilter.branches(branches, query: "e/l").map(\.name) == ["feature/login-page"], "slash is part of the matched name")
        #expect(BranchFilter.branches(branches, query: "nope").isEmpty)
    }

    @Test func surroundingWhitespaceIsIgnored() {
        #expect(BranchFilter.isActive(" fix "))
        #expect(BranchFilter.branches(branches, query: "  fix  ").map(\.name) == ["fix/typo"])
    }

    @Test func currentBranchIsNotExemptFromTheFilter() {
        #expect(BranchFilter.branches(branches, query: "feature").allSatisfy { !$0.isCurrent })
    }

    @Test func remotesMatchOnJoinedNameAndDropEmptyRemotes() {
        let byRemoteName = BranchFilter.remotes(remotes, query: "origin")
        #expect(byRemoteName.map(\.name) == ["origin"])
        #expect(byRemoteName.first?.branches == ["main", "feature/login-page"], "remote name alone keeps all of its branches")

        let joined = BranchFilter.remotes(remotes, query: "origin/main")
        #expect(joined.count == 1 && joined.first?.branches == ["main"])

        let byBranch = BranchFilter.remotes(remotes, query: "main")
        #expect(byBranch.map(\.name) == ["origin", "upstream"])
        #expect(byBranch.map(\.branches) == [["main"], ["main"]])

        let release = BranchFilter.remotes(remotes, query: "release")
        #expect(release.map(\.name) == ["upstream"], "origin has no match and is dropped")
    }

    @Test func tagsMatchOnName() {
        #expect(BranchFilter.tags(tags, query: "rc").map(\.name) == ["v2.0.0-rc1"])
        #expect(BranchFilter.tags(tags, query: "v").count == 2)
        #expect(BranchFilter.tags(tags, query: "main").isEmpty)
    }
}
