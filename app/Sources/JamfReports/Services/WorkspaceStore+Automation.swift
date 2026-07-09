import Foundation

// MARK: - Automation health (dead-man switch, 2.6 trust trio #2)

/// One thing wrong with a scheduled agent. Absence of a run becomes signal:
/// a schedule that SHOULD have fired but produced no artifact is `.overdue`,
/// and a schedule whose latest artifact reports failure is `.failing`.
struct AutomationHealthIssue: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable {
        case overdue
        case failing
    }

    /// Stable per-agent id (the LaunchAgent label) so SwiftUI keeps row identity.
    var id: String { label }
    let label: String
    let displayName: String
    let kind: Kind
    /// When the schedule should have last fired (`.overdue`) — nil is not
    /// expected for a produced issue but kept optional for the model's purity.
    let expectedFire: Date?
    /// When the last recorded run finished, if any (`.failing`, or last success).
    let lastRunFinishedAt: Date?
}

/// Pure evaluator for the scheduled-run dead-man switch. Given the raw
/// per-schedule inputs, returns the issues an operator needs to see. No I/O,
/// no launchctl, no real LaunchAgents dir — unit-tested directly.
enum AutomationHealth {

    /// Grace after the expected fire before a run is called overdue. Scheduled
    /// runs take a few minutes; 60 min absorbs launchd jitter, a slow collect,
    /// and clock skew without hiding a genuinely-missed run.
    static let graceSeconds: TimeInterval = 60 * 60

    /// Evaluate one probe pass. `now` is injected for deterministic tests.
    ///
    /// - `.overdue`: the schedule is enabled, has an expected past fire, that
    ///   fire plus the grace window has elapsed, and there is no run artifact
    ///   finishing at or after the expected fire.
    /// - `.failing`: a run artifact exists and its success flag is `false`
    ///   (independent of overdue — a run that fired but failed still needs
    ///   attention). A schedule can be both; overdue takes precedence so the
    ///   operator sees the more urgent "nothing ran" state first.
    ///
    /// Disabled schedules never produce an issue.
    static func evaluate(
        inputs: [LaunchAgentService.ScheduleHealthInput],
        now: Date = Date()
    ) -> [AutomationHealthIssue] {
        inputs.compactMap { input in
            guard input.enabled else { return nil }

            if let expected = input.expectedFire,
               now.timeIntervalSince(expected) >= graceSeconds,
               !ranAtOrAfter(input.lastRunFinishedAt, expected) {
                return AutomationHealthIssue(
                    label: input.label,
                    displayName: input.displayName,
                    kind: .overdue,
                    expectedFire: expected,
                    lastRunFinishedAt: input.lastRunFinishedAt
                )
            }

            if input.lastRunSuccess == false {
                return AutomationHealthIssue(
                    label: input.label,
                    displayName: input.displayName,
                    kind: .failing,
                    expectedFire: input.expectedFire,
                    lastRunFinishedAt: input.lastRunFinishedAt
                )
            }

            return nil
        }
    }

    /// True when a run artifact finished at or after the expected fire — i.e.
    /// the scheduled run for this cycle is accounted for.
    private static func ranAtOrAfter(_ finished: Date?, _ expected: Date) -> Bool {
        guard let finished else { return false }
        return finished >= expected
    }
}

/// Observable holder for the current automation-health issues. Kept as a shared
/// `@Observable` model (read in a view body → Observation tracks it) because the
/// primary `WorkspaceStore` declaration cannot gain a stored property from this
/// extension. Recomputed at app launch via the reconcile chain.
@MainActor
@Observable
final class AutomationHealthModel {
    static let shared = AutomationHealthModel()
    private init() {}

    var issues: [AutomationHealthIssue] = []
}

// MARK: - Managed automation wiring

extension WorkspaceStore {

    /// Current automation-health issues (overdue / failing schedules). Reads
    /// the shared observable so any view that references it re-renders on change.
    var automationHealthIssues: [AutomationHealthIssue] {
        AutomationHealthModel.shared.issues
    }

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
    func reconcileManagedAutomation() async -> [ManagedAutomation.ActionOutcome] {
        guard !demoMode else { return [] }
        let outcomes = await ManagedAutomation.reconcile(policy: AutomationPolicy.current())
        // The install/remove above can change what "should have fired" — recompute
        // the dead-man state on the same chain so the banner reflects it at once.
        await refreshAutomationHealth()
        return outcomes
    }

    // MARK: - Dead-man switch compute

    /// Scan the JRC LaunchAgents, evaluate the overdue/failing model, publish the
    /// issues to the shared health model, and (once per day) post an overdue
    /// webhook digest when `notify:` is usable. No-op in demo mode. Cheap enough
    /// to call on every reconcile / launch.
    func refreshAutomationHealth() async {
        guard !demoMode else {
            AutomationHealthModel.shared.issues = []
            return
        }
        let profile = self.profile
        // Scan + evaluate off the main actor; both are pure file reads.
        let issues = await Task.detached(priority: .utility) {
            AutomationHealth.evaluate(inputs: LaunchAgentService.healthInputs())
        }.value
        AutomationHealthModel.shared.issues = issues

        await maybeNotifyOverdue(issues: issues, profile: profile)
    }

    /// Post ONE overdue digest per day when any schedule is overdue AND the
    /// workspace's `notify:` webhook is usable. Reuses the attention-styled
    /// `sendFailed` path (an overdue run is a run-health failure). Skips entirely
    /// when the config can't be loaded or the webhook is off.
    private func maybeNotifyOverdue(issues: [AutomationHealthIssue], profile: String) async {
        let overdue = issues.filter { $0.kind == .overdue }
        guard !overdue.isEmpty else { return }
        guard let notify = Self.loadNotifyConfig(profile: profile), notify.isUsable,
              let workspace = ProfileService.workspaceURL(for: profile) else { return }
        // Persisted day marker (not an in-memory static): survives relaunch and
        // is visible to a headless process, so the digest fires at most once per
        // calendar day across both.
        let today = Self.dayKeyFormatter.string(from: Date())
        let marker = DayMarker(name: "overdue-notify")
        guard marker.lastStampedDay(in: workspace) != today else { return }

        let facts = Self.overdueFacts(
            detail: notify.resolvedDetail, profile: profile, overdue: overdue
        )
        let delivered = await WebhookNotifier.sendFailed(
            config: notify,
            title: "Scheduled run overdue — \(overdue.count) schedule"
                + (overdue.count == 1 ? "" : "s"),
            facts: facts
        )
        // Claim the day only after a confirmed send, so a failed post retries
        // on the next pass instead of silently swallowing the whole day.
        if delivered {
            marker.stamp(day: today, in: workspace)
        } else {
            AppLogger.webhook.warning(
                "Overdue dead-man digest failed to send for \(profile, privacy: .public) — day not claimed, will retry (distinct from a routine run digest failure)"
            )
        }
    }

    /// Facts for the overdue dead-man digest. `full` mode lists each overdue
    /// schedule (display name → expected-fire date). `minimal` collapses to a
    /// Profile fact plus a single count with no schedule names or dates — the
    /// digest becomes a doorbell for headless high-security deployments.
    nonisolated static func overdueFacts(
        detail: NotifyConfig.Detail,
        profile: String,
        overdue: [AutomationHealthIssue]
    ) -> [WebhookNotifier.Fact] {
        guard detail == .full else {
            let word = overdue.count == 1 ? "schedule" : "schedules"
            return [
                .init(label: "Profile", value: profile),
                .init(label: "Overdue", value: "\(overdue.count) \(word) missed their run"),
            ]
        }
        return overdue.prefix(10).map { issue in
            WebhookNotifier.Fact(
                label: issue.displayName,
                value: issue.expectedFire.map {
                    "expected \(ISO8601DateFormatter().string(from: $0)); no run recorded"
                } ?? "no run recorded"
            )
        }
    }

    /// Load just the `notify:` block for a profile's config.yaml. Best-effort —
    /// returns nil when the workspace has no config or it fails to decode.
    nonisolated private static func loadNotifyConfig(profile: String) -> NotifyConfig? {
        guard ProfileService.isValid(profile),
              let url = ProfileService.workspaceURL(for: profile)?
                .appendingPathComponent("config.yaml"),
              FileManager.default.fileExists(atPath: url.path),
              let config = try? ConfigLoader.load(from: url) else {
            return nil
        }
        return config.notify
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
