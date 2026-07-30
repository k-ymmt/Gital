import Foundation

/// Bounds an async operation to a wall-clock budget by racing it against a
/// sleeping child task; whichever finishes first cancels the other. The
/// operation must be cancellation-aware for the bound to mean anything —
/// git subprocesses are (`Subprocess` terminates the child on cancellation).
enum Timeout {
    struct Expired: Error {}

    static func run<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw Expired()
            }
            // The first child to finish decides the outcome; the loser is
            // cancelled here and awaited on group exit.
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
