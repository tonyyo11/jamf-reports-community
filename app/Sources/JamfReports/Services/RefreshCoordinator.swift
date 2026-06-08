import Foundation

/// Coordinates per-profile, per-tier snapshot refreshes.
///
/// Checks snapshot staleness on the filesystem (mtime of the newest file in
/// `jamf-cli-data/<tier-probe-kind>/`) and triggers a `.refresh`-tier collect
/// when the data is older than the active preset's cadence × 1.5 (ADR Q1).
/// Coalesces concurrent requests so a `.refresh` already in flight is never
/// double-queued.
///
/// Keyed on `CollectionTier`. Only `.refresh` is wired today — it's the
/// cheap, frequent tier that feeds the Overview KPIs. `.inventory`/`.scan`
/// requests log and no-op; they'd slot into the same machinery if a future
/// "catch up" affordance needs them.
///
/// `observeProfileSwitch` is the entry point for the sidebar profile chip:
/// switching profiles triggers a debounced `.refresh` check so the Overview
/// screen loads fresh data promptly without hammering the server.
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

    /// Debounce task for profile-switch refresh.
    private var profileSwitchDebounce: Task<Void, Never>?

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
    /// - `tier` is not `.refresh` (only the refresh tier is wired — see type doc).
    /// - A refresh for this profile+tier is already in progress.
    /// - Backoff is active due to consecutive failures.
    /// - Data is fresh (newest snapshot mtime is within the staleness threshold).
    func refreshIfStale(profile: String, tier: CollectionTier) {
        guard ProfileService.isValid(profile) else { return }
        guard tier == .refresh else {
            AppLogger.engine.info(
                "RefreshCoordinator: tier \(tier.rawValue, privacy: .public) not wired; only .refresh is handled"
            )
            return
        }
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
    /// `.refresh` refreshes — a common pattern when the user cycles through
    /// profiles while looking for the right one.
    func observeProfileSwitch(_ newProfile: String) {
        profileSwitchDebounce?.cancel()
        profileSwitchDebounce = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }
            self.refreshIfStale(profile: newProfile, tier: .refresh)
        }
    }

    // MARK: - Status accessors

    /// True when a refresh is currently running for `profile` and `tier`.
    func isRefreshing(profile: String, tier: CollectionTier) -> Bool {
        activeTasks[TierKey(profile: profile, tier: tier)] != nil
    }

    /// Current consecutive failure count for `profile` and `tier`.
    func failureCount(profile: String, tier: CollectionTier) -> Int {
        failureCounts[TierKey(profile: profile, tier: tier), default: 0]
    }

    // MARK: - Private

    private func performRefresh(
        profile: String,
        tier: CollectionTier,
        key: TierKey
    ) async {
        defer { activeTasks.removeValue(forKey: key) }

        // Re-check staleness inside the task: another task may have refreshed
        // while this one was waiting on the actor.
        guard await isDataStale(profile: profile, tier: tier) else { return }

        lastAttempts[key] = Date()

        // Backfill only the requested tier — a profile-switch refresh should
        // not pull every list endpoint and per-device scan (PR-22 T-9 tier set).
        // force: true bypasses the once-per-day guard; the coordinator already
        // gates on staleness, so the guard is redundant and would silently no-op
        // a user-triggered profile-switch refresh that ran after a scheduled collect.
        let exitCode: Int32
        do {
            exitCode = try await bridge.collect(
                profile: profile, tiers: [tier], force: true, onLine: CLIBridge.noOpOnLine
            )
        } catch {
            failureCounts[key, default: 0] += 1
            AppLogger.cli.warning(
                "Background refresh threw for \(profile)/\(tier.rawValue): \(error.localizedDescription, privacy: .private)"
            )
            return
        }

        if exitCode == 0 {
            failureCounts[key] = 0
            lastSuccessfulRefresh[profile] = Date()
            // Snapshot retention now lives in ReportEngine.collect
            // (SnapshotRetentionService.sweepIfDue) so it runs once/day on every
            // collect path — headless scheduled runs included — and honors the
            // config (OFF by default). The old hardcoded delete-at-90-days sweep
            // here only ran while the app was open; it is removed.
        } else {
            failureCounts[key, default: 0] += 1
            let consecutive = failureCounts[key, default: 0]
            AppLogger.cli.warning(
                "Background refresh failed for \(profile)/\(tier.rawValue): exit \(exitCode), consecutive failures: \(consecutive)"
            )
        }
    }


    /// Returns `true` when the newest snapshot for `tier` is older than the
    /// staleness threshold, or when no snapshot exists at all.
    ///
    /// The threshold is preset-aware (ADR Q1): the active preset's resolved
    /// cadence for the tier's probe kind × 1.5. A `.never` cadence means the
    /// report is intentionally not collected — never "stale", so no backfill.
    /// Falls back to `RefreshPolicy.stalenessThreshold` when `config.yaml`
    /// can't be read.
    private func isDataStale(profile: String, tier: CollectionTier) async -> Bool {
        let fallback = policy.stalenessThreshold(for: tier)
        return await Task.detached(priority: .utility) {
            guard let dataDir = try? WorkspacePaths.dataDir(for: profile) else { return true }

            switch Self.resolvedStalenessThreshold(profile: profile, tier: tier, fallback: fallback) {
            case .none:
                // Probe kind resolves to cadence .never — not collected, not stale.
                return false
            case .some(let threshold):
                let dir = dataDir.appendingPathComponent(
                    tier.stalenessProbeKind, isDirectory: true
                )
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
            }
        }.value
    }

    /// Resolve the preset-aware staleness threshold for `tier`.
    ///
    /// Returns `nil` when the tier's probe kind resolves to cadence `.never`
    /// (intentionally not collected — never triggers a backfill). Otherwise
    /// returns the resolved cadence × 1.5. Falls back to `fallback` when the
    /// config can't be read.
    ///
    /// `nonisolated` so the `Task.detached` staleness probe can call it off
    /// the main actor — it only touches the filesystem and pure resolvers,
    /// no `RefreshCoordinator` state.
    nonisolated private static func resolvedStalenessThreshold(
        profile: String,
        tier: CollectionTier,
        fallback: TimeInterval
    ) -> TimeInterval? {
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            return fallback
        }
        let configURL = workspace.appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: configURL.path),
              let config = try? ConfigLoader.load(from: configURL) else {
            return fallback
        }
        let cadence = CadenceResolver.resolve(
            report: tier.stalenessProbeKind, config: config.collectCadence
        )
        switch cadence {
        case .never:
            return nil
        case .seconds(let n):
            return TimeInterval(n) * 1.5
        }
    }
}

// MARK: - TierKey

/// Hashable key for profile + tier combinations used in dictionaries.
private struct TierKey: Hashable {
    let profile: String
    let tier: CollectionTier
}
