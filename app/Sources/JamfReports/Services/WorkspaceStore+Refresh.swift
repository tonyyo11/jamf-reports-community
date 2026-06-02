import AppKit
import Foundation

// MARK: - RefreshCoordinator wiring

/// Owns the `RefreshCoordinator` singleton and all call sites that fire into it.
///
/// Keeps `WorkspaceStore.swift` minimally edited: the store exposes `coordinator`
/// for the sidebar UI and calls `triggerRefresh()` from its two mutation points
/// (profile switch and app-foreground notification).
extension WorkspaceStore {

    // MARK: Coordinator accessor

    /// Shared coordinator for the process lifetime.
    ///
    /// Stored as an associated-object on self to avoid adding a stored property to
    /// the `@Observable` class (which would require modifying the primary file's
    /// observation tracking). The coordinator is created once and reused.
    var coordinator: RefreshCoordinator {
        if let existing = objc_getAssociatedObject(self, &WorkspaceStore.coordinatorKey)
            as? RefreshCoordinator
        {
            return existing
        }
        let new = RefreshCoordinator(bridge: CLIBridge())
        objc_setAssociatedObject(
            self,
            &WorkspaceStore.coordinatorKey,
            new,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return new
    }

    private static var coordinatorKey: UInt8 = 0
    private static var foregroundObserverKey: UInt8 = 0

    // MARK: Refresh gate

    /// Whether a background refresh may run for `profileSlug`.
    ///
    /// False in demo mode — the demo workspace has no real Jamf data to
    /// fetch — and false for slugs that fail the profile-name validator.
    /// `RefreshCoordinator` has no demo concept, so this gate lives at the
    /// `WorkspaceStore` boundary and both refresh entry points consult it.
    ///
    /// (There is deliberately no `profileSlug != "demo"` check: the demo
    /// profile is `DemoData.org.profile` ("meridian-prod"), not "demo", so
    /// such a literal never matched. `demoMode` is the real gate.)
    func canRefresh(profileSlug: String) -> Bool {
        !demoMode && ProfileService.isValid(profileSlug)
    }

    // MARK: Public trigger

    /// Fire a `.refresh`-tier refresh for `profile`, subject to coordinator
    /// backoff/coalescing. No-ops when `canRefresh` is false.
    func triggerRefresh(for profileSlug: String) {
        guard canRefresh(profileSlug: profileSlug) else { return }
        coordinator.refreshIfStale(profile: profileSlug, tier: .refresh)
    }

    /// Fire a debounced `.refresh`-tier check after a profile switch.
    ///
    /// Routed through `RefreshCoordinator.observeProfileSwitch` (500 ms
    /// debounce) so cycling the sidebar chip through several profiles
    /// doesn't spawn a refresh per intermediate selection. No-ops when
    /// `canRefresh` is false.
    func observeProfileSwitchRefresh(for profileSlug: String) {
        guard canRefresh(profileSlug: profileSlug) else { return }
        coordinator.observeProfileSwitch(profileSlug)
    }

    // MARK: Heavy-tier staleness (launch prompt)

    /// Age threshold (days) past which heavy-tier data triggers the Overview
    /// refresh prompt and audit data auto-refreshes on launch.
    nonisolated static let heavyTierStaleDays = 7

    /// Populate `staleHeavyTiers` with the .inventory / .scan tiers whose
    /// newest probe-kind snapshot is older than `heavyTierStaleDays`.
    ///
    /// Heavy tiers are never auto-collected — per-device queries can stall
    /// on-prem Jamf Pro for minutes. The Overview prompt's button is the only
    /// trigger (`runHeavyTierRefresh`).
    func checkHeavyTierStaleness() async {
        guard canRefresh(profileSlug: profile) else {
            staleHeavyTiers = []
            return
        }
        let activeProfile = profile
        let threshold = TimeInterval(Self.heavyTierStaleDays) * 86_400
        let stale = await Task.detached(priority: .utility) {
            Self.staleTiers(profile: activeProfile, olderThan: threshold)
        }.value
        // Profile may have switched while the probe ran off-actor.
        guard profile == activeProfile else { return }
        staleHeavyTiers = stale
    }

    /// Collect the currently-stale heavy tiers, then clear the prompt.
    /// Surfaces progress through `globalStatus` and a completion toast.
    func runHeavyTierRefresh() async {
        let tiers = staleHeavyTiers
        guard !tiers.isEmpty, canRefresh(profileSlug: profile) else { return }
        let activeProfile = profile
        let labels = tiers.map(\.displayName).joined(separator: " + ")
        globalStatus = "refreshing \(labels) data · profile=\(activeProfile)"
        defer { globalStatus = nil }
        do {
            let exit = try await CLIBridge().collect(
                profile: activeProfile, tiers: Set(tiers), onLine: CLIBridge.noOpOnLine
            )
            if exit == 0 {
                staleHeavyTiers = []
                toast = Toast(message: "\(labels) data refreshed", style: .success)
            } else {
                toast = Toast(
                    message: "Refresh finished with exit \(exit) — see Runs for details",
                    style: .danger
                )
            }
        } catch {
            toast = Toast(message: "Refresh failed — \(error.localizedDescription)", style: .danger)
        }
    }

    /// Run a Health Audit in the background when the cached audit snapshot is
    /// older than `heavyTierStaleDays`. Part of the launch-time freshness
    /// sweep — audit is a configuration-analysis call (no per-device
    /// enumeration), so unlike the heavy tiers it is safe to run unprompted.
    func autoRefreshAuditIfStale() async {
        guard canRefresh(profileSlug: profile) else { return }
        let activeProfile = profile
        let threshold = TimeInterval(Self.heavyTierStaleDays) * 86_400
        let auditIsStale = await Task.detached(priority: .utility) {
            Self.newestSnapshotAge(profile: activeProfile, kind: "audit")
                .map { $0 >= threshold } ?? true
        }.value
        guard auditIsStale, profile == activeProfile else { return }

        AppLogger.cli.info(
            "Launch freshness sweep: audit data older than \(Self.heavyTierStaleDays) days — refreshing"
        )
        do {
            _ = try await CLIBridge().audit(
                profile: activeProfile, category: nil, onLine: CLIBridge.noOpOnLine
            )
        } catch {
            AppLogger.cli.warning(
                "Launch audit refresh failed: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    /// Heavy tiers whose newest probe-kind snapshot is older than `threshold`.
    /// A tier with no snapshots at all is NOT reported — that's the
    /// not-yet-collected state, which the per-page empty states already cover.
    nonisolated static func staleTiers(
        profile: String,
        olderThan threshold: TimeInterval
    ) -> [CollectionTier] {
        [CollectionTier.inventory, .scan].filter { tier in
            guard let age = newestSnapshotAge(profile: profile, kind: tier.stalenessProbeKind) else {
                return false
            }
            return age >= threshold
        }
    }

    /// Age in seconds of the newest .json snapshot under
    /// `<workspace>/jamf-cli-data/<kind>/`, or nil when none exist.
    nonisolated static func newestSnapshotAge(profile: String, kind: String) -> TimeInterval? {
        guard let dataDir = try? WorkspacePaths.dataDir(for: profile) else { return nil }
        let dir = dataDir.appendingPathComponent(kind, isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let newest = entries
            .filter { $0.pathExtension == "json" }
            .compactMap {
                (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
            }
            .max()
        guard let newest else { return nil }
        return Date().timeIntervalSince(newest)
    }

    // MARK: App-foreground registration

    /// Register for `NSApplication.willBecomeActiveNotification` so the
    /// active profile's Refresh-tier data is re-checked when the app comes
    /// back to the foreground.
    ///
    /// Called once from the root view's `.task`. Genuinely idempotent: the
    /// observer token is stashed as an associated object and a second call
    /// returns early, so a shell re-mount cannot stack duplicate observers.
    func registerForegroundRefresh() {
        if objc_getAssociatedObject(self, &WorkspaceStore.foregroundObserverKey) != nil {
            return
        }
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.willBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.triggerRefresh(for: self.profile)
            }
        }
        objc_setAssociatedObject(
            self,
            &WorkspaceStore.foregroundObserverKey,
            token,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}

// MARK: - Data-driven tab set

extension Tab {
    /// True when switching to this tab should trigger a `.refresh`-tier data refresh.
    ///
    /// Configuration and log surfaces are excluded: refreshing when the user
    /// navigates to Schedules or Runs would be noisy and misleading.
    var isDataDriven: Bool {
        switch self {
        case .overview, .fleet, .devices, .deviceLookup, .trends, .audit, .reports,
             .securityPosture, .compliancePosture, .complianceBenchmarks,
             .patch, .updates, .ddmBlueprints,
             .policyProfile, .extensionAttributes,
             .outreach, .protectDashboard, .mobileFleet, .groupInventory:
            return true
        case .schedules, .runs, .config, .customize, .sources, .backups, .settings, .onboarding:
            return false
        }
    }
}
