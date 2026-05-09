import Foundation

/// Coordinates per-profile, per-tier snapshot refreshes.
///
/// Checks snapshot staleness on the filesystem (mtime of the newest file in
/// `jamf-cli-data/<tier-kind>/`) and triggers `CLIBridge.collect` when the
/// data is older than `RefreshPolicy.stalenessThreshold`. Coalesces concurrent
/// requests so a `.hot` refresh already in flight is never double-queued.
///
/// `observeProfileSwitch` is the entry point for the sidebar profile chip:
/// switching profiles triggers a debounced `.hot` check so the Overview screen
/// loads fresh data promptly without hammering the server.
@MainActor
@Observable
final class RefreshCoordinator {

    // MARK: - State

    /// Failure counters per profile+tier. Reset to 0 on success.
    private var failureCounts: [TierKey: Int] = [:]

    /// Timestamp of the last attempt (success or failure) per profile+tier.
    private var lastAttempts: [TierKey: Date] = [:]

    /// Timestamp of the last *successful* refresh per profile. Used for sidebar display.
    var lastSuccessfulRefresh: [String: Date] = [:]

    /// In-flight refresh tasks per profile+tier. Used for coalescing.
    private var activeTasks: [TierKey: Task<Void, Never>] = [:]

    /// Debounce task for profile-switch hot refresh.
    private var profileSwitchDebounce: Task<Void, Never>?

    /// Last successful snapshot-retention sweep per profile. The cold-tier
    /// completion path triggers a sweep only when 24 h have elapsed since the
    /// previous one — without this guard, a noisy environment that runs
    /// `.cold` more than once a day would re-sweep on every successful refresh.
    private var lastRetentionSweep: [String: Date] = [:]

    /// Minimum gap between automatic retention sweeps for a given profile.
    private let retentionSweepCooldown: TimeInterval = 86_400  // 24 hours

    private let policy: RefreshPolicy
    private let bridge: CLIBridge

    // MARK: - Init

    init(bridge: CLIBridge, policy: RefreshPolicy = .default) {
        self.bridge = bridge
        self.policy = policy
    }

    // MARK: - Public API

    /// Check whether `tier` data for `profile` is stale; if so, trigger a refresh.
    ///
    /// No-ops when:
    /// - Profile is invalid.
    /// - A refresh for this profile+tier is already in progress.
    /// - Backoff is active due to consecutive failures.
    /// - Data is fresh (newest snapshot mtime is within the staleness threshold).
    func refreshIfStale(profile: String, tier: ScheduleTier) {
        guard ProfileService.isValid(profile) else { return }
        let key = TierKey(profile: profile, tier: tier)

        // Coalesce: don't queue the same tier twice.
        guard activeTasks[key] == nil else { return }

        // Backoff check.
        let failures = failureCounts[key, default: 0]
        if let last = lastAttempts[key],
           policy.shouldBackOff(tier: tier, failureCount: failures, lastAttempt: last) {
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(profile: profile, tier: tier, key: key)
        }
        activeTasks[key] = task
    }

    /// Called by the sidebar chip when the active profile changes.
    ///
    /// Debounces 500 ms so rapid profile switches don't spawn many concurrent
    /// `.hot` refreshes — a common pattern when the user cycles through profiles
    /// while looking for the right one.
    func observeProfileSwitch(_ newProfile: String) {
        profileSwitchDebounce?.cancel()
        profileSwitchDebounce = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }
            self.refreshIfStale(profile: newProfile, tier: .hot)
        }
    }

    // MARK: - Status accessors

    /// True when a refresh is currently running for `profile` and `tier`.
    func isRefreshing(profile: String, tier: ScheduleTier) -> Bool {
        activeTasks[TierKey(profile: profile, tier: tier)] != nil
    }

    /// Current consecutive failure count for `profile` and `tier`.
    func failureCount(profile: String, tier: ScheduleTier) -> Int {
        failureCounts[TierKey(profile: profile, tier: tier), default: 0]
    }

    // MARK: - Private

    private func performRefresh(
        profile: String,
        tier: ScheduleTier,
        key: TierKey
    ) async {
        defer { activeTasks.removeValue(forKey: key) }

        // Re-check staleness inside the task: another task may have refreshed
        // while this one was waiting on the actor.
        guard await isDataStale(profile: profile, tier: tier) else { return }

        lastAttempts[key] = Date()

        let exitCode = await bridge.collect(profile: profile, onLine: { _ in })

        if exitCode == 0 {
            failureCounts[key] = 0
            lastSuccessfulRefresh[profile] = Date()
            if tier == .cold {
                runRetentionSweepIfDue(profile: profile)
            }
        } else {
            failureCounts[key, default: 0] += 1
        }
    }

    /// Sweep `<profile>/jamf-cli-data/*` if the per-profile cooldown has elapsed.
    /// No-ops on the same day to keep the cold-tier hot-path cheap.
    private func runRetentionSweepIfDue(profile: String) {
        let now = Date()
        if let last = lastRetentionSweep[profile],
           now.timeIntervalSince(last) < retentionSweepCooldown {
            return
        }
        lastRetentionSweep[profile] = now
        do {
            _ = try SnapshotRetentionService.sweep(profile: profile)
        } catch {
            AppLogger.engine.warning(
                "RefreshCoordinator: retention sweep for '\(profile)' failed: \(error)"
            )
        }
    }

    /// Returns `true` when the newest snapshot for `tier` is older than the
    /// policy's staleness threshold, or when no snapshot exists at all.
    private func isDataStale(profile: String, tier: ScheduleTier) async -> Bool {
        let threshold = policy.stalenessThreshold(for: tier)
        return await Task.detached(priority: .utility) {
            guard let dataDir = try? WorkspacePaths.dataDir(for: profile) else { return true }

            let dir = dataDir.appendingPathComponent(tier.stalenessProbeKind, isDirectory: true)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                return true
            }

            let newest = entries
                .filter { $0.pathExtension == "json" }
                .compactMap {
                    (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate
                }
                .max()

            guard let newest else { return true }
            return Date().timeIntervalSince(newest) >= threshold
        }.value
    }
}

// MARK: - TierKey

/// Hashable key for profile + tier combinations used in dictionaries.
private struct TierKey: Hashable {
    let profile: String
    let tier: ScheduleTier
}
