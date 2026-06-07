import Foundation

// MARK: - Managed automation wiring

extension WorkspaceStore {

    /// Reconcile the managed-automation LaunchAgents from the saved
    /// `AutomationPolicy`. Called from the root view's `.task` at launch AND
    /// from the Automation screen whenever the policy changes, so enabling
    /// "Manage automation" (or editing the cadence) takes effect immediately
    /// instead of waiting for the next app launch.
    ///
    /// No-ops in demo mode. Safe to call when automation is unmanaged: the
    /// reconcile plan is then empty for a user who never opted in, and tears
    /// down any leftover managed agents if the operator turned the policy off.
    /// Returns the install/remove actions it applied (empty when nothing
    /// changed) so callers can surface confirmation.
    @discardableResult
    func reconcileManagedAutomation() async -> [ManagedAutomation.Action] {
        guard !demoMode else { return [] }
        return await ManagedAutomation.reconcile(policy: AutomationPolicy.current())
    }

    // MARK: - Catch-up-on-wake

    /// One in-memory guard so the catch-up sweep runs at most once per calendar
    /// day per app run, no matter how often the app is focused. The engine's
    /// once-per-day summary guard is the real dedupe; this just avoids
    /// re-statting every profile on each `willBecomeActive`.
    @MainActor private static var lastCatchUpDay: String?

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Backstop for laptops that slept through the scheduled freshness run:
    /// when managed freshness is on, collect today's daily-freshness snapshot
    /// (tiers refresh+inventory) for every non-excluded profile if it hasn't
    /// happened yet. Uses the Phase-1 `force: false` once-per-day guard, so a
    /// profile already collected today is a cheap no-op.
    ///
    /// Called from app launch and `willBecomeActive` (Mac wake / app focus).
    /// Runs off the main actor, sequentially per profile (mirroring
    /// `--multi-sequential`) so launch doesn't jank and on-prem isn't hit in
    /// parallel.
    func catchUpCollectIfNeeded() async {
        guard !demoMode else { return }
        let policy = AutomationPolicy.current()
        // Bail before any filesystem scan in the common unmanaged case, and on
        // repeat focuses once today's sweep has been claimed.
        guard policy.isManaged, policy.freshnessEnabled else { return }
        let today = Self.dayKeyFormatter.string(from: Date())
        guard Self.lastCatchUpDay != today else { return }

        let targets = Self.catchUpTargets(
            policy: policy, discovered: ProfileService.discoverLocal().map(\.name)
        )
        guard !targets.isEmpty else { return }
        Self.lastCatchUpDay = today  // claim the day (no await before this) to prevent re-entry

        await Self.runCatchUp(profiles: targets)
    }

    /// Profiles eligible for a catch-up collect: only when the policy manages
    /// freshness, minus excluded and invalid slugs. Pure — unit-tested.
    nonisolated static func catchUpTargets(
        policy: AutomationPolicy,
        discovered: [String]
    ) -> [String] {
        guard policy.isManaged, policy.freshnessEnabled else { return [] }
        let excluded = Set(policy.excludedProfiles)
        return discovered.filter { ProfileService.isValid($0) && !excluded.contains($0) }
    }

    /// Sequential per-profile catch-up collect, off the main actor.
    nonisolated private static func runCatchUp(profiles: [String]) async {
        for profile in profiles {
            await catchUpOne(profile)
        }
    }

    nonisolated private static func catchUpOne(_ profile: String) async {
        let config: ReportConfig? = {
            guard let url = ProfileService.workspaceURL(for: profile)?
                .appendingPathComponent("config.yaml"),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try? ConfigLoader.load(from: url)
        }()
        do {
            try await CollectRouter.run(
                profile: profile,
                tiers: [.refresh, .inventory],
                skipExpensive: false,
                force: false,  // once-per-day guard: no-op if already collected today
                config: config,
                onLine: CLIBridge.noOpOnLine
            )
        } catch {
            AppLogger.cli.warning(
                "Catch-up collect failed for \(profile, privacy: .public): \(error.localizedDescription, privacy: .private)"
            )
        }
    }
}
