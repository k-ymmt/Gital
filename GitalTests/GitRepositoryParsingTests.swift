import Foundation
import Testing
@testable import Gital

@MainActor
struct GitRepositoryParsingTests {
    @Test func statusParsing() {
        var statusData = Data()
        for token in [
            "# branch.oid 0123456789abcdef",
            "# branch.head feature/onboarding",
            "# branch.upstream origin/feature/onboarding",
            "# branch.ab +2 -1",
            "1 .M N... 100644 100644 100644 aaaa bbbb Sources/App/AppDelegate.swift",
            "1 M. N... 100644 100644 100644 aaaa bbbb Sources/Onboarding/OnboardingCarousel.swift",
            "2 R. N... 100644 100644 100644 aaaa bbbb R100 Sources/New.swift",
            "Sources/Old.swift",
            "? Resources/welcome_1.png",
        ] {
            statusData.append(token.data(using: .utf8)!)
            statusData.append(0)
        }

        let status = GitRepository.parseStatus(statusData)
        #expect(status.branch == "feature/onboarding", "status branch")
        #expect(status.upstream == "origin/feature/onboarding", "status upstream")
        #expect(status.ahead == 2 && status.behind == 1, "status ahead/behind")
        #expect(status.unstaged.count == 2, "status unstaged count")
        #expect(status.staged.count == 2, "status staged count")
        #expect(status.staged.contains { $0.path == "Sources/New.swift" && $0.originalPath == "Sources/Old.swift" && $0.status == .renamed },
                "status rename entry")
        #expect(status.unstaged.contains { $0.path == "Resources/welcome_1.png" && $0.status == .untracked },
                "status untracked entry")
    }

    // Regression: conflict entries, detached HEAD, and paths with spaces.
    @Test func statusConflictDetachedSpaces() {
        var statusData = Data()
        for token in [
            "# branch.head (detached)",
            "1 .M N... 100644 100644 100644 aaaa bbbb My File.txt",
            "u UU N... 100644 100644 100644 100644 aaaa bbbb cccc Merge Conflict.swift",
        ] {
            statusData.append(token.data(using: .utf8)!)
            statusData.append(0)
        }
        let status = GitRepository.parseStatus(statusData)
        #expect(status.branch == nil, "detached HEAD parses as nil branch")
        #expect(status.unstaged.contains { $0.path == "My File.txt" && $0.status == .modified },
                "path with spaces survives status parsing")
        #expect(status.unstaged.contains { $0.path == "Merge Conflict.swift" && $0.status == .conflicted },
                "conflicted u entry parses")
    }

    @Test func logParsing() {
        let logOutput = [
            ["aaa111", "bbb222", "Kenji Mori", "kenji@aurora.app", "2 hours ago", "Polish welcome carousel", "HEAD -> feature/onboarding, origin/feature/onboarding"].joined(separator: "\u{0}"),
            ["bbb222", "ccc333 ddd444", "Aiko Tanaka", "aiko@aurora.app", "Yesterday", "Merge branch 'main'", "tag: v1.2.0, main"].joined(separator: "\u{0}"),
        ].joined(separator: "\n")

        let commits = GitRepository.parseLog(logOutput, remotes: ["origin"])
        #expect(commits.count == 2, "log parses two commits")
        #expect(commits[0].refs.contains { $0.kind == .head && $0.name == "feature/onboarding" }, "log HEAD ref")
        #expect(commits[0].refs.contains { $0.kind == .remoteBranch && $0.name == "origin/feature/onboarding" }, "log remote ref")
        #expect(commits[1].parents == ["ccc333", "ddd444"], "log merge parents")
        #expect(commits[1].refs.contains { $0.kind == .tag && $0.name == "v1.2.0" }, "log tag ref")
        #expect(commits[1].refs.contains { $0.kind == .branch && $0.name == "main" }, "log branch ref")
    }

    // Local branches containing "/" must not be mistaken for remote branches.
    @Test func refKindClassification() {
        #expect(GitRepository.parseRefs("feature/login", remotes: ["origin"]).first?.kind == .branch, "slash-named local branch stays local")
        #expect(GitRepository.parseRefs("origin/main", remotes: ["origin"]).first?.kind == .remoteBranch, "known remote prefix is remote")
    }

    // A subject containing legacy 0x1E/0x1F separator bytes must not corrupt
    // record splitting (NUL separators make this impossible).
    @Test func hostileSubjectBytes() {
        let hostileLog = ["eee555", "", "Mallory", "m@x", "now", "subject with \u{1e} and \u{1f} bytes", ""].joined(separator: "\u{0}")
        let hostileCommits = GitRepository.parseLog(hostileLog)
        #expect(hostileCommits.count == 1 && hostileCommits[0].subject == "subject with \u{1e} and \u{1f} bytes",
                "hostile subject bytes survive log parsing")
    }

    @Test func branchListParsing() {
        let branchOutput = [
            ["main", "*", "origin/main", "aaa111", "origin"].joined(separator: "\u{1f}"),
            ["feature/login", "", "", "bbb222", ""].joined(separator: "\u{1f}"),
            ["localtrack", "", "main", "ccc333", "."].joined(separator: "\u{1f}"),
        ].joined(separator: "\n")
        let parsedBranches = GitRepository.parseBranches(branchOutput)
        #expect(parsedBranches.count == 3, "branch list parses three branches")
        #expect(parsedBranches[0].isCurrent && parsedBranches[0].upstream == "origin/main", "current branch with upstream")
        #expect(parsedBranches[0].upstreamRemote == "origin" && !parsedBranches[0].tracksLocalBranch, "remote upstream carries its remote name")
        #expect(parsedBranches[1].upstream == nil && parsedBranches[1].upstreamRemote == nil, "branch without upstream has nil upstream")
        #expect(parsedBranches[2].tracksLocalBranch, "'.' remotename marks a local-tracking branch")
    }

    // Detached HEAD: `git branch` emits a "(HEAD detached at abc1234)"
    // placeholder entry that must not surface as a branch.
    @Test func detachedHeadPlaceholder() {
        let detachedOutput = [
            ["(HEAD detached at aaa1111)", "*", "", "aaa111"].joined(separator: "\u{1f}"),
            ["main", "", "origin/main", "bbb222"].joined(separator: "\u{1f}"),
        ].joined(separator: "\n")
        let detachedBranches = GitRepository.parseBranches(detachedOutput)
        #expect(detachedBranches.count == 1 && detachedBranches[0].name == "main", "detached HEAD placeholder is not a branch")
        #expect(!detachedBranches.contains { $0.isCurrent }, "detached HEAD has no current branch")
    }

    @Test func tagListParsing() {
        let tagOutput = [
            ["v1.1.0", "tagobj111", "peeled111"].joined(separator: "\u{1f}"),   // annotated
            ["v1.0.0", "commit000", ""].joined(separator: "\u{1f}"),            // lightweight
        ].joined(separator: "\n")
        let parsedTags = GitRepository.parseTags(tagOutput)
        #expect(parsedTags.count == 2, "tag list parses two tags")
        #expect(parsedTags[0].tipHash == "peeled111", "annotated tag uses peeled commit hash")
        #expect(parsedTags[1].tipHash == "commit000", "lightweight tag uses object hash directly")
    }

    @Test func stashListParsing() {
        let stashOutput = [
            ["stash@{0}", "aaa111", "WIP on main: something"].joined(separator: "\u{1f}"),
            ["stash@{1}", "bbb222", "On feature: other"].joined(separator: "\u{1f}"),
        ].joined(separator: "\n")
        let parsedStashes = GitRepository.parseStashes(stashOutput)
        #expect(parsedStashes.count == 2, "stash list parses two stashes")
        #expect(parsedStashes[0].reference == "stash@{0}" && parsedStashes[0].index == 0, "stash reference and index")
        #expect(parsedStashes[1].commitHash == "bbb222" && parsedStashes[1].message == "On feature: other", "stash hash and message")
    }

    @Test func commitDetailParsing() {
        let detailOutput = [
            "aaa111bbb222ccc333ddd444eee555fff666aaa1",
            "p1p1p1 p2p2p2",
            "Kenji Mori", "kenji@aurora.app", "2026-07-25 10:30:00",
            "GitHub", "noreply@github.com", "2026-07-25 11:00:00",
            "HEAD -> main, tag: v2.0.0",
            "Polish welcome carousel\n\nMulti-line body with details.\nSecond body line.\n",
        ].joined(separator: "\u{0}")

        let detail = GitRepository.parseCommitDetail(detailOutput, remotes: ["origin"])
        #expect(detail != nil, "commit detail parses")
        #expect(detail?.hash == "aaa111bbb222ccc333ddd444eee555fff666aaa1", "detail full hash")
        #expect(detail?.parents == ["p1p1p1", "p2p2p2"], "detail parents")
        #expect(detail?.author == "Kenji Mori" && detail?.authorDate == "2026-07-25 10:30:00", "detail author fields")
        #expect(detail?.hasDistinctCommitter == true, "detail distinct committer detected")
        #expect(detail?.message == "Polish welcome carousel\n\nMulti-line body with details.\nSecond body line.",
                "detail multi-line message survives NUL splitting")
        #expect(detail?.refs.contains { $0.kind == .head && $0.name == "main" } == true, "detail HEAD ref")
        #expect(detail?.refs.contains { $0.kind == .tag && $0.name == "v2.0.0" } == true, "detail tag ref")

        let sameCommitterDetail = GitRepository.parseCommitDetail([
            "abc", "", "A", "a@a", "2026-01-01 00:00:00", "A", "a@a", "2026-01-01 00:00:00", "", "msg",
        ].joined(separator: "\u{0}"))
        #expect(sameCommitterDetail?.hasDistinctCommitter == false, "detail same committer not flagged")
        #expect(GitRepository.parseCommitDetail("") == nil, "empty detail output yields nil")
    }

    // Regression: commit stats parse renames via -z.
    @Test func commitStatsParsing() {
        var numstatZ = Data()
        for token in ["5\t2\t", "old dir/old.txt", "new dir/new.txt", "1\t0\tplain.txt"] {
            numstatZ.append(token.data(using: .utf8)!)
            numstatZ.append(0)
        }
        var nameStatusZ = Data()
        for token in ["R100", "old dir/old.txt", "new dir/new.txt", "M", "plain.txt"] {
            nameStatusZ.append(token.data(using: .utf8)!)
            nameStatusZ.append(0)
        }
        let commitStats = GitRepository.parseCommitStats(numstat: numstatZ, nameStatus: nameStatusZ)
        #expect(commitStats.contains { $0.path == "new dir/new.txt" && $0.oldPath == "old dir/old.txt" && $0.status == .renamed && $0.additions == 5 && $0.deletions == 2 },
                "renamed file stat keeps both real paths")
        #expect(commitStats.contains { $0.path == "plain.txt" && $0.status == .modified && $0.additions == 1 },
                "plain file stat parses alongside a rename")
    }
}
