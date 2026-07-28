import Foundation

/// Guards an async load pipeline against stale completion: each `run` cancels
/// the previous in-flight operation and, once its own operation finishes,
/// reports back only while still the latest — a slow stale load can never
/// overwrite the state a newer one produced. Replaces the hand-written
/// bump-generation / guard-generation idiom that every loader had to repeat.
@MainActor
final class LatestLoader {
    private var generation = 0
    private var cancelInFlight: (() -> Void)?

    /// Runs `operation`, returning its outcome — or nil when a newer `run`
    /// (or `invalidate`) superseded this one while it was awaiting, or when
    /// the operation was cancelled. Callers assign state only on non-nil.
    func run<T>(_ operation: @escaping @MainActor () async throws -> T) async -> Result<T, Error>? {
        generation += 1
        let current = generation
        cancelInFlight?()
        let task = Task { try await operation() }
        cancelInFlight = { task.cancel() }

        let result: Result<T, Error>
        do {
            result = .success(try await task.value)
        } catch {
            result = .failure(error)
        }
        guard current == generation else { return nil }
        cancelInFlight = nil
        if case .failure(let error) = result, error is CancellationError { return nil }
        return result
    }

    /// Supersedes any in-flight run without starting a new one — for the
    /// "selection cleared" paths that reset state directly.
    func invalidate() {
        generation += 1
        cancelInFlight?()
        cancelInFlight = nil
    }
}
