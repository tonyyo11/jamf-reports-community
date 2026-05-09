import Foundation

/// Per-tier staleness thresholds, failure backoff constants, and derived timing
/// helpers for `RefreshCoordinator`.
///
/// All time values are in seconds. Defaults match `ScheduleTier.intervalSeconds`
/// so that the in-app refresh coordinator and the LaunchAgent fire on the same
/// cadence — there is no benefit to refreshing in-app more frequently than the
/// background agent would.
struct RefreshPolicy: Sendable {

    // MARK: - Per-tier thresholds

    /// Minimum age (seconds) before a snapshot is considered stale for each tier.
    ///
    /// Defaults equal `ScheduleTier.intervalSeconds` so that a snapshot
    /// collected by the LaunchAgent is never immediately re-fetched when the
    /// user opens the app.
    let stalenessThresholds: [ScheduleTier: TimeInterval]

    /// Maximum consecutive failures before exponential backoff engages.
    ///
    /// After this many failures the coordinator skips the next scheduled refresh
    /// and doubles the wait each time (capped by `maxBackoffMultiplier`).
    let maxConsecutiveFailures: [ScheduleTier: Int]

    // MARK: - Backoff constants

    /// Base multiplier for exponential backoff: wait = interval × 2^failures.
    ///
    /// A value of 2 doubles the interval on the first backed-off attempt,
    /// quadruples on the second, etc. Capped at `maxBackoffMultiplier`.
    let backoffBase: Double

    /// Upper bound on the backoff multiplier.
    ///
    /// Prevents runaway waits on persistent failures. With a 24-hour cold tier,
    /// a cap of 8 means the maximum wait is 8 × 24 h = 8 days — beyond which a
    /// device that's been offline for days is unlikely to produce new data anyway.
    let maxBackoffMultiplier: Double

    // MARK: - Defaults

    /// Default policy whose cadence matches the `ScheduleTier` intervals.
    static let `default` = RefreshPolicy(
        stalenessThresholds: [
            .hot:  TimeInterval(ScheduleTier.hot.intervalSeconds),   // 900 s
            .warm: TimeInterval(ScheduleTier.warm.intervalSeconds),  // 14 400 s
            .cold: TimeInterval(ScheduleTier.cold.intervalSeconds),  // 86 400 s
        ],
        maxConsecutiveFailures: [
            .hot:  3,
            .warm: 2,
            .cold: 2,
        ],
        backoffBase: 2.0,
        maxBackoffMultiplier: 8.0
    )

    // MARK: - Derived helpers

    /// Staleness threshold for `tier`, falling back to the tier's own interval.
    func stalenessThreshold(for tier: ScheduleTier) -> TimeInterval {
        stalenessThresholds[tier] ?? TimeInterval(tier.intervalSeconds)
    }

    /// Max consecutive failures for `tier`, falling back to 2.
    func maxFailures(for tier: ScheduleTier) -> Int {
        maxConsecutiveFailures[tier] ?? 2
    }

    /// Effective wait interval after `failureCount` consecutive failures.
    ///
    /// Returns `interval × min(2^failureCount, maxBackoffMultiplier)`.
    /// When `failureCount == 0` the result equals `interval` (no backoff).
    func backoffInterval(tier: ScheduleTier, failureCount: Int) -> TimeInterval {
        guard failureCount > 0 else { return TimeInterval(tier.intervalSeconds) }
        let raw = pow(backoffBase, Double(failureCount))
        let multiplier = min(raw, maxBackoffMultiplier)
        return TimeInterval(tier.intervalSeconds) * multiplier
    }

    /// True when the coordinator should skip a refresh because of accumulated failures.
    ///
    /// Skips when `failureCount >= maxFailures` AND the time since `lastAttempt`
    /// is less than the computed backoff interval.
    func shouldBackOff(
        tier: ScheduleTier,
        failureCount: Int,
        lastAttempt: Date,
        now: Date = Date()
    ) -> Bool {
        guard failureCount >= maxFailures(for: tier) else { return false }
        let elapsed = now.timeIntervalSince(lastAttempt)
        return elapsed < backoffInterval(tier: tier, failureCount: failureCount)
    }
}
