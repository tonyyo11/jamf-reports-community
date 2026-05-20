import Foundation

/// Per-tier staleness thresholds, failure backoff constants, and derived timing
/// helpers for `RefreshCoordinator`.
///
/// All time values are in seconds. Keyed on `CollectionTier`.
/// `RefreshCoordinator` only ever drives the `.refresh` tier today
/// (profile-switch + app-foreground backfill), so the maps are populated for
/// `.refresh` only — `.inventory`/`.scan` fall through to the keyless
/// defaults rather than carrying ghost entries nothing reads.
struct RefreshPolicy: Sendable {

    // MARK: - Per-tier thresholds

    /// Minimum age (seconds) before a snapshot is considered stale for a tier.
    ///
    /// This is the *fallback* staleness threshold — `RefreshCoordinator`
    /// prefers a preset-aware value (the active preset's `.refresh` cadence
    /// × 1.5, ADR Q1) and only falls back here when `config.yaml` can't be
    /// read.
    let stalenessThresholds: [CollectionTier: TimeInterval]

    /// Maximum consecutive failures before exponential backoff engages.
    ///
    /// After this many failures the coordinator skips the next scheduled refresh
    /// and doubles the wait each time (capped by `maxBackoffMultiplier`).
    let maxConsecutiveFailures: [CollectionTier: Int]

    // MARK: - Backoff constants

    /// Base multiplier for exponential backoff: wait = interval × 2^failures.
    ///
    /// A value of 2 doubles the interval on the first backed-off attempt,
    /// quadruples on the second, etc. Capped at `maxBackoffMultiplier`.
    let backoffBase: Double

    /// Upper bound on the backoff multiplier.
    ///
    /// Prevents runaway waits on persistent failures. With a daily Refresh
    /// tier, a cap of 8 means the maximum wait is 8 days — beyond which a
    /// server that's been failing that long needs operator attention, not
    /// another automatic retry.
    let maxBackoffMultiplier: Double

    // MARK: - Defaults

    /// Default policy. Only `.refresh` is populated — it's the sole tier
    /// `RefreshCoordinator` drives. The staleness fallback is the on-prem
    /// Refresh cadence × 1.5 (matches the preset-aware path's formula so a
    /// config-read failure degrades to the same number, not a surprise).
    static let `default` = RefreshPolicy(
        stalenessThresholds: [
            .refresh: TimeInterval(CollectionTier.refresh.intervalSeconds) * 1.5,
        ],
        maxConsecutiveFailures: [
            .refresh: 3,
        ],
        backoffBase: 2.0,
        maxBackoffMultiplier: 8.0
    )

    // MARK: - Derived helpers

    /// Staleness threshold for `tier`, falling back to the tier's own interval
    /// when the map has no entry.
    func stalenessThreshold(for tier: CollectionTier) -> TimeInterval {
        stalenessThresholds[tier] ?? TimeInterval(tier.intervalSeconds)
    }

    /// Max consecutive failures for `tier`, falling back to 2.
    func maxFailures(for tier: CollectionTier) -> Int {
        maxConsecutiveFailures[tier] ?? 2
    }

    /// Effective wait interval after `failureCount` consecutive failures.
    ///
    /// Returns `interval × min(2^failureCount, maxBackoffMultiplier)`.
    /// When `failureCount == 0` the result equals `interval` (no backoff).
    func backoffInterval(tier: CollectionTier, failureCount: Int) -> TimeInterval {
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
        tier: CollectionTier,
        failureCount: Int,
        lastAttempt: Date,
        now: Date = Date()
    ) -> Bool {
        guard failureCount >= maxFailures(for: tier) else { return false }
        let elapsed = now.timeIntervalSince(lastAttempt)
        return elapsed < backoffInterval(tier: tier, failureCount: failureCount)
    }
}
