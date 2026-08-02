import Foundation
import Testing
@testable import Gital

// Regression suite: process waiting must never wedge the serialized chain.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct GitExecutorTests {
    init() {
        // The app ignores SIGPIPE (GitalApp.init); the unconsumed-stdin test
        // writes into a closed pipe and needs the same protection here.
        signal(SIGPIPE, SIG_IGN)
    }

    /// Creates a temp directory with an initialized git repository and hands
    /// it to `body` together with an executor rooted there.
    private func withTempRepo(_ body: (GitExecutor) async throws -> Void) async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gital-executor-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let executor = GitExecutor(workingDirectory: tempRoot)
        _ = try await executor.run(["init"])
        try await body(executor)
    }

    // Launch failure (nonexistent cwd) must throw promptly, leave the
    // DispatchGroup balanced (unbalanced enters crash on dealloc), and not hang.
    @Test func launchFailureThrows() async {
        let broken = GitExecutor(workingDirectory: URL(fileURLWithPath: "/nonexistent-gital-test-dir"))
        let launchFailed = (try? await broken.run(["version"])) == nil
        #expect(launchFailed, "launch failure throws instead of hanging")
    }

    // A failing command (non-zero exit) must not stall the serialized chain.
    @Test func chainSurvivesFailingCommand() async throws {
        try await withTempRepo { executor in
            _ = try? await executor.run(["rev-parse", "no-such-ref"])
            let toplevel = (try? await executor.run(["rev-parse", "--show-toplevel"])) ?? ""
            #expect(!toplevel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "chain survives a failing command")
        }
    }

    // stdin round-trip, and stdin that git exits without consuming.
    @Test func stdinHandling() async throws {
        try await withTempRepo { executor in
            let hash = (try? await executor.run(["hash-object", "--stdin"], stdin: Data("hello\n".utf8))) ?? ""
            #expect(hash.trimmingCharacters(in: .whitespacesAndNewlines).count == 40,
                    "stdin is delivered to git")
            let badSubcommand = (try? await executor.run(
                ["not-a-real-subcommand"], stdin: Data(repeating: 65, count: 1 << 20)
            )) == nil
            #expect(badSubcommand, "unconsumed stdin surfaces the error, no hang")
        }
    }

    // A background child inheriting the pipes (fsmonitor-daemon style) holds
    // EOF back after git exits; the drain grace cutoff must finish the
    // command with the output produced before exit instead of wedging.
    @Test func drainGraceCutoff() async throws {
        try await withTempRepo { executor in
            let leakStart = Date()
            let leaked = (try? await executor.run(
                ["-c", "alias.leak=!echo started; sleep 10 >/dev/null &", "leak"]
            )) ?? ""
            let leakElapsed = Date().timeIntervalSince(leakStart)
            #expect(leaked.contains("started"), "pre-exit output survives the drain cutoff")
            #expect(leakElapsed < GitExecutor.drainGracePeriod + 5,
                    "orphaned pipe holder cannot wedge the chain (took \(String(format: "%.1f", leakElapsed))s)")
            let afterLeak = (try? await executor.run(["rev-parse", "--show-toplevel"])) != nil
            #expect(afterLeak, "chain keeps serving commands after the cutoff")
        }
    }

    // Cancelling a caller must terminate its long-running command (instead
    // of returning output or a GitError) and leave the chain serving.
    @Test func cancellationTerminatesCommand() async throws {
        try await withTempRepo { executor in
            let slowTask = Task { try await executor.run(["-c", "alias.slow=!sleep 20", "slow"]) }
            try? await Task.sleep(nanoseconds: 300_000_000)
            let cancelStart = Date()
            slowTask.cancel()
            let cancelledResult = try? await slowTask.value
            let cancelElapsed = Date().timeIntervalSince(cancelStart)
            #expect(cancelledResult == nil, "cancelled command yields no result")
            #expect(cancelElapsed < 15,
                    "cancellation terminates the command promptly (took \(String(format: "%.1f", cancelElapsed))s)")
            let afterCancel = (try? await executor.run(["rev-parse", "--show-toplevel"])) != nil
            #expect(afterCancel, "chain keeps serving after a cancellation")
        }
    }

    // A network-lane command hanging on a dead remote must not stall local
    // commands — the regression was a wedged `git fetch` freezing every
    // status/diff/log (the Working Copy pane stopped following file
    // selection) until the fetch died.
    @Test func networkLaneDoesNotBlockLocalLane() async throws {
        try await withTempRepo { executor in
            let slowFetch = Task {
                try await executor.run(
                    ["-c", "alias.slownet=!sleep 5 && touch net.done", "slownet"], lane: .network
                )
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            let seen = (try? await executor.run(
                ["-c", "alias.probe=!test -f net.done && echo present || echo missing", "probe"]
            )) ?? ""
            #expect(seen.contains("missing"), "local command ran while the network command was still hanging")
            slowFetch.cancel()
            _ = try? await slowFetch.value
        }
    }

    // Two network commands must still serialize with each other — concurrent
    // fetches would race on remote-tracking ref locks.
    @Test func networkLaneSerializesItself() async throws {
        try await withTempRepo { executor in
            let first = Task {
                try await executor.run(
                    ["-c", "alias.netone=!sleep 1 && touch n1.done", "netone"], lane: .network
                )
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            let seen = (try? await executor.run(
                ["-c", "alias.nettwo=!test -f n1.done && echo present || echo missing", "nettwo"],
                lane: .network
            )) ?? ""
            #expect(seen.contains("present"), "second network command waited for the first")
            _ = try? await first.value
        }
    }

    // An exclusive command (pull) must wait for BOTH lanes: it rewrites the
    // worktree (can't overlap local commands) and talks to the remote (can't
    // overlap an in-flight fetch).
    @Test func exclusiveLaneWaitsForBothLanes() async throws {
        try await withTempRepo { executor in
            let slowLocal = Task {
                try await executor.run(["-c", "alias.slowloc=!sleep 1 && touch local.done", "slowloc"])
            }
            let slowNetwork = Task {
                try await executor.run(
                    ["-c", "alias.slownet=!sleep 1 && touch net.done", "slownet"], lane: .network
                )
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            let seen = (try? await executor.run(
                ["-c", "alias.excl=!ls local.done net.done 2>/dev/null | wc -l", "excl"],
                lane: .exclusive
            )) ?? ""
            #expect(seen.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("2"),
                    "exclusive command waited for both lanes (saw: \(seen))")
            _ = try? await slowLocal.value
            _ = try? await slowNetwork.value
        }
    }

    // And the mirror image: once an exclusive command is queued, both lanes
    // must wait behind it — a fetch overlapping a pull's worktree rewrite
    // races on the same remote refs.
    @Test func bothLanesWaitBehindExclusive() async throws {
        try await withTempRepo { executor in
            let exclusive = Task {
                try await executor.run(
                    ["-c", "alias.slowexcl=!sleep 1 && touch ex.done", "slowexcl"], lane: .exclusive
                )
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            async let localSeen = executor.run(
                ["-c", "alias.locprobe=!test -f ex.done && echo present || echo missing", "locprobe"]
            )
            async let networkSeen = executor.run(
                ["-c", "alias.netprobe=!test -f ex.done && echo present || echo missing", "netprobe"],
                lane: .network
            )
            let local = (try? await localSeen) ?? ""
            let network = (try? await networkSeen) ?? ""
            #expect(local.contains("present"), "local command waited behind the exclusive command")
            #expect(network.contains("present"), "network command waited behind the exclusive command")
            _ = try? await exclusive.value
        }
    }

    // Hammer the chain with concurrent mixed success/failure commands; every
    // call must complete with the expected outcome.
    @Test func concurrentMixedCommands() async throws {
        try await withTempRepo { executor in
            let outcomes = await withTaskGroup(of: Bool.self) { group -> [Bool] in
                for i in 0..<60 {
                    group.addTask {
                        if i % 5 == 0 {
                            return (try? await executor.run(["rev-parse", "bad-ref-\(i)"])) == nil
                        }
                        return (try? await executor.run(["rev-parse", "--show-toplevel"])) != nil
                    }
                }
                var results: [Bool] = []
                for await outcome in group { results.append(outcome) }
                return results
            }
            #expect(outcomes.count == 60 && outcomes.allSatisfy { $0 },
                    "60 concurrent commands all complete correctly")
        }
    }
}
