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
        let now = ContinuousClock.now
        #expect(!AutoFetchPreference.shouldFetch(lastFetch: now - .seconds(30), now: now, interval: 60))
    }

    @Test func tickAfterFullIntervalFetches() {
        let now = ContinuousClock.now
        #expect(AutoFetchPreference.shouldFetch(lastFetch: now - .seconds(60), now: now, interval: 60))
    }

    @Test func jitterSlackAllowsSlightlyEarlyTick() {
        // Task.sleep can wake fractionally early relative to the recorded
        // instant; the 1-second slack keeps the owning loop from starving.
        let now = ContinuousClock.now
        #expect(AutoFetchPreference.shouldFetch(lastFetch: now - .seconds(59.5), now: now, interval: 60))
    }
}
