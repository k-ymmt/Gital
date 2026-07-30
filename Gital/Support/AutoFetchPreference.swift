import Foundation

/// Policy and persistence for the periodic background `git fetch`.
enum AutoFetchPreference {
    /// UserDefaults key for the interval in seconds; 0 disables auto fetch.
    static let defaultsKey = "autoFetchIntervalSeconds"
    static let defaultInterval: TimeInterval = 60

    /// Whether a timer tick should actually run a fetch. Each window hosting
    /// the repository drives its own tick loop, so two windows would double
    /// the fetch rate; requiring (almost) a full interval since the last run
    /// collapses the duplicates to one effective fetcher. The 1-second slack
    /// covers timer scheduling jitter — without it a tick that fires right on
    /// time could measure fractionally under its own interval and starve.
    static func shouldFetch(lastFetch: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard interval > 0 else { return false }
        guard let lastFetch else { return true }
        return now.timeIntervalSince(lastFetch) >= interval - 1
    }
}
