import Foundation
import Testing

@testable import Gital

@MainActor
struct AutoFetchPreferenceTests {
    @Test func firstTickFetches() {
        #expect(AutoFetchPreference.shouldFetch(lastFetch: nil, now: .now, interval: 60))
    }

    @Test func disabledIntervalNeverFetches() {
        #expect(!AutoFetchPreference.shouldFetch(lastFetch: nil, now: .now, interval: 0))
        #expect(!AutoFetchPreference.shouldFetch(lastFetch: nil, now: .now, interval: -5))
    }

    @Test func duplicateTickFromSecondWindowIsSkipped() {
        // A second window's loop firing halfway through the interval must
        // not double the fetch rate.
        let now = Date.now
        #expect(!AutoFetchPreference.shouldFetch(lastFetch: now.addingTimeInterval(-30), now: now, interval: 60))
    }

    @Test func tickAfterFullIntervalFetches() {
        let now = Date.now
        #expect(AutoFetchPreference.shouldFetch(lastFetch: now.addingTimeInterval(-60), now: now, interval: 60))
    }

    @Test func jitterSlackAllowsSlightlyEarlyTick() {
        // Task.sleep can wake fractionally early relative to the recorded
        // timestamp; the 1-second slack keeps the owning loop from starving.
        let now = Date.now
        #expect(AutoFetchPreference.shouldFetch(lastFetch: now.addingTimeInterval(-59.5), now: now, interval: 60))
    }
}
