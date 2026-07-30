import Foundation
import Testing

@testable import Gital

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TimeoutTests {
    @Test func fastOperationReturnsItsValue() async throws {
        let value = try await Timeout.run(seconds: 5) { 42 }
        #expect(value == 42)
    }

    @Test func operationErrorPropagates() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await Timeout.run(seconds: 5) { throw Boom() }
        }
    }

    @Test func slowOperationThrowsExpiredPromptly() async {
        // The operation sleeps far past the budget; Expired must win the
        // race (and the suite's time limit proves the loser was cancelled
        // rather than awaited to completion).
        await #expect(throws: Timeout.Expired.self) {
            try await Timeout.run(seconds: 0.05) {
                try await Task.sleep(for: .seconds(600))
            }
        }
    }
}
