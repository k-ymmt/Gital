import Foundation
import Testing
@testable import Gital

@MainActor
struct BranchOperationsTests {
    // MARK: - Current-branch push arguments

    @Test func pushWithUpstreamIsPlain() {
        #expect(GitRepository.pushArguments(
            currentBranch: "main", upstreamRemote: "origin", upstreamMerge: "refs/heads/main", force: false
        ) == ["push"])
    }

    // A bare `push --force-with-lease` obeys push.default; under "matching"
    // it would force-push every matching branch. The forced form must carry
    // an explicit refspec naming only the confirmed branch.
    @Test func forcePushCarriesExplicitRefspec() {
        #expect(GitRepository.pushArguments(
            currentBranch: "main", upstreamRemote: "origin", upstreamMerge: "refs/heads/main", force: true
        ) == ["push", "--force-with-lease", "origin", "main:refs/heads/main"])
    }

    @Test func forcePushHonorsDifferentlyNamedUpstream() {
        #expect(GitRepository.pushArguments(
            currentBranch: "local", upstreamRemote: "fork", upstreamMerge: "refs/heads/other", force: true
        ) == ["push", "--force-with-lease", "fork", "local:refs/heads/other"])
    }

    @Test func pushWithoutUpstreamSetsUpstreamOnOrigin() {
        #expect(GitRepository.pushArguments(
            currentBranch: "feature/x", upstreamRemote: nil, upstreamMerge: nil, force: false
        ) == ["push", "--set-upstream", "origin", "feature/x"])
    }

    @Test func forcePushWithoutUpstreamKeepsBothFlags() {
        #expect(GitRepository.pushArguments(
            currentBranch: "main", upstreamRemote: nil, upstreamMerge: nil, force: true
        ) == ["push", "--force-with-lease", "--set-upstream", "origin", "main"])
    }

    // A half-configured upstream (remote without merge) reads as "no
    // upstream" — matching git's own @{upstream} resolution.
    @Test func partialUpstreamConfigReadsAsNoUpstream() {
        #expect(GitRepository.pushArguments(
            currentBranch: "main", upstreamRemote: "origin", upstreamMerge: nil, force: false
        ) == ["push", "--set-upstream", "origin", "main"])
    }

    // Detached HEAD: never create a branch literally named "HEAD" — plain
    // push lets git report the real problem.
    @Test func detachedHeadPushStaysPlain() {
        #expect(GitRepository.pushArguments(
            currentBranch: "HEAD", upstreamRemote: nil, upstreamMerge: nil, force: false
        ) == ["push"])
    }

    @Test func detachedHeadForcePushStaysPlain() {
        #expect(GitRepository.pushArguments(
            currentBranch: "HEAD", upstreamRemote: nil, upstreamMerge: nil, force: true
        ) == ["push", "--force-with-lease"])
    }

    // MARK: - Specific-branch push arguments

    @Test func branchWithUpstreamPushesExplicitFullRefspec() throws {
        #expect(try GitRepository.pushBranchArguments(
            branch: "feature/x", pushRemote: nil, fetchRemote: "origin", upstreamMerge: "refs/heads/feature/x"
        ) == ["push", "origin", "feature/x:refs/heads/feature/x"])
    }

    // The upstream branch may be named differently from the local branch;
    // the refspec must target the upstream ref, not the local name.
    @Test func differentlyNamedUpstreamPushesToUpstreamRef() throws {
        #expect(try GitRepository.pushBranchArguments(
            branch: "local", pushRemote: nil, fetchRemote: "fork", upstreamMerge: "refs/heads/remote-name"
        ) == ["push", "fork", "local:refs/heads/remote-name"])
    }

    // Triangular workflow: branch.<name>.pushRemote / remote.pushDefault wins
    // over the fetch remote, and pushes the branch under its own name.
    @Test func pushRemoteWinsOverFetchRemote() throws {
        #expect(try GitRepository.pushBranchArguments(
            branch: "topic", pushRemote: "myfork", fetchRemote: "upstream", upstreamMerge: "refs/heads/topic"
        ) == ["push", "myfork", "topic:refs/heads/topic"])
    }

    @Test func branchWithoutUpstreamPublishesToOrigin() throws {
        #expect(try GitRepository.pushBranchArguments(
            branch: "feature/x", pushRemote: nil, fetchRemote: nil, upstreamMerge: nil
        ) == ["push", "--set-upstream", "origin", "feature/x"])
    }

    // branch.<name>.remote = "." tracks a local branch — pushing there is
    // meaningless, and silently republishing to origin would rewrite the
    // branch's tracking configuration. Must refuse.
    @Test func localDotRemoteThrows() {
        #expect(throws: BranchOperationError.self) {
            try GitRepository.pushBranchArguments(
                branch: "feature/x", pushRemote: nil, fetchRemote: ".", upstreamMerge: "refs/heads/main"
            )
        }
    }

    @Test func localDotPushRemoteThrows() {
        #expect(throws: BranchOperationError.self) {
            try GitRepository.pushBranchArguments(
                branch: "feature/x", pushRemote: ".", fetchRemote: nil, upstreamMerge: nil
            )
        }
    }

    // A half-configured upstream must refuse rather than guess a remote —
    // a wrong guess rewrites tracking config under the user.
    @Test func incompleteUpstreamConfigThrows() {
        #expect(throws: BranchOperationError.self) {
            try GitRepository.pushBranchArguments(
                branch: "x", pushRemote: nil, fetchRemote: "origin", upstreamMerge: nil
            )
        }
        #expect(throws: BranchOperationError.self) {
            try GitRepository.pushBranchArguments(
                branch: "x", pushRemote: nil, fetchRemote: nil, upstreamMerge: "refs/heads/x"
            )
        }
    }
}
