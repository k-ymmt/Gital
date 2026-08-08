import Foundation
import Testing
@testable import Gital

/// The supersession primitive every loader in the app depends on — the
/// guard-generation and cancellation-forwarding paths are exactly what
/// silently regresses.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LatestLoaderTests {

    private struct TestError: Error {}

    @Test func deliversTheLatestResult() async throws {
        let loader = LatestLoader()
        let result = await loader.run { 42 }
        #expect(try result?.get() == 42)
    }

    @Test func failuresSurfaceAsFailure() async {
        let loader = LatestLoader()
        let result: Result<Int, Error>? = await loader.run { throw TestError() }
        guard case .failure(let error)? = result else {
            Issue.record("expected a failure result")
            return
        }
        #expect(error is TestError)
    }

    @Test func cancellationIsSwallowedNotReported() async {
        let loader = LatestLoader()
        let result: Result<Int, Error>? = await loader.run { throw CancellationError() }
        #expect(result == nil)
    }

    @Test func newerRunSupersedesAndCancelsTheOlder() async throws {
        let loader = LatestLoader()
        var firstStarted = false
        var firstSawCancellation: Bool?
        var release: CheckedContinuation<Void, Never>?

        let first = Task { @MainActor in
            await loader.run {
                firstStarted = true
                await withCheckedContinuation { release = $0 }
                firstSawCancellation = Task.isCancelled
                return 1
            }
        }
        while !firstStarted { await Task.yield() }

        // The newer run wins immediately; it must not wait for the old one.
        let second = await loader.run { 2 }
        #expect(try second?.get() == 2)

        release?.resume()
        let firstResult = await first.value
        #expect(firstResult == nil, "superseded run must not report back")
        #expect(firstSawCancellation == true, "superseded operation must be cancelled, not left running")
    }

    @Test func invalidateSuppressesTheInFlightRun() async {
        let loader = LatestLoader()
        var started = false
        var release: CheckedContinuation<Void, Never>?

        let inFlight = Task { @MainActor in
            await loader.run {
                started = true
                await withCheckedContinuation { release = $0 }
                return 1
            }
        }
        while !started { await Task.yield() }

        loader.invalidate()
        release?.resume()
        let result = await inFlight.value
        #expect(result == nil, "an invalidated run must not report back")
    }

    @Test func consumerCancellationForwardsToTheOperation() async {
        let loader = LatestLoader()
        var started = false
        var sawCancellation: Bool?
        var release: CheckedContinuation<Void, Never>?

        let consumer = Task { @MainActor in
            await loader.run {
                started = true
                await withCheckedContinuation { release = $0 }
                sawCancellation = Task.isCancelled
                return 1
            }
        }
        while !started { await Task.yield() }

        // Cancelling the awaiting consumer (a dismissed view) must reach the
        // inner operation — otherwise its git subprocess runs to completion
        // on the serialized executor.
        consumer.cancel()
        release?.resume()
        _ = await consumer.value
        while sawCancellation == nil { await Task.yield() }
        #expect(sawCancellation == true)
    }
}
