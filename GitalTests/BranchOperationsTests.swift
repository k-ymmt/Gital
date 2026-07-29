import Foundation
import Testing
@testable import Gital

@MainActor
struct BranchOperationsTests {
    // MARK: - Current-branch push arguments

    @Test func pushWithUpstreamIsPlain() {
        #expect(GitRepository.pushArguments(hasUpstream: true, currentBranch: nil, force: false) == ["push"])
    }

    @Test func forcePushUsesForceWithLease() {
        #expect(GitRepository.pushArguments(hasUpstream: true, currentBranch: nil, force: true)
                == ["push", "--force-with-lease"])
    }

    @Test func pushWithoutUpstreamSetsUpstreamOnOrigin() {
        #expect(GitRepository.pushArguments(hasUpstream: false, currentBranch: "feature/x", force: false)
                == ["push", "--set-upstream", "origin", "feature/x"])
    }

    @Test func forcePushWithoutUpstreamKeepsBothFlags() {
        #expect(GitRepository.pushArguments(hasUpstream: false, currentBranch: "main", force: true)
                == ["push", "--force-with-lease", "--set-upstream", "origin", "main"])
    }

    // Detached HEAD: never create a branch literally named "HEAD" — plain
    // push lets git report the real problem.
    @Test func detachedHeadPushStaysPlain() {
        #expect(GitRepository.pushArguments(hasUpstream: false, currentBranch: "HEAD", force: false) == ["push"])
    }

    // MARK: - Specific-branch push arguments

    @Test func branchWithUpstreamPushesExplicitRefspec() {
        #expect(GitRepository.pushBranchArguments(branch: "feature/x", upstream: "origin/feature/x", configuredRemote: "origin")
                == ["push", "origin", "feature/x:feature/x"])
    }

    // The upstream branch may be named differently from the local branch;
    // the refspec must target the upstream name, not the local one.
    @Test func differentlyNamedUpstreamPushesToUpstreamName() {
        #expect(GitRepository.pushBranchArguments(branch: "local", upstream: "fork/remote-name", configuredRemote: "fork")
                == ["push", "fork", "local:remote-name"])
    }

    @Test func branchWithoutUpstreamPublishesToOrigin() {
        #expect(GitRepository.pushBranchArguments(branch: "feature/x", upstream: nil, configuredRemote: nil)
                == ["push", "--set-upstream", "origin", "feature/x"])
    }

    // branch.<name>.remote can be "." (a local upstream) — pushing there is
    // meaningless, so it falls back to publishing on origin.
    @Test func localDotRemoteFallsBackToOrigin() {
        #expect(GitRepository.pushBranchArguments(branch: "feature/x", upstream: "main", configuredRemote: ".")
                == ["push", "--set-upstream", "origin", "feature/x"])
    }

    // A remote whose name is a prefix of another ("o" vs "origin") must not
    // steal the upstream: the prefix match requires the "/" separator.
    @Test func upstreamOutsideConfiguredRemoteFallsBackToOrigin() {
        #expect(GitRepository.pushBranchArguments(branch: "x", upstream: "origin/x", configuredRemote: "o")
                == ["push", "--set-upstream", "origin", "x"])
    }
}
