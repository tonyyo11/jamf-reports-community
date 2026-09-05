import Foundation

// MARK: - Automation health (dead-man switch, 2.6 trust trio #2)

/// One thing wrong with a scheduled agent. Absence of a run becomes signal:
/// a schedule that SHOULD have fired but produced no artifact is `.overdue`,
/// and a schedule whose latest artifact reports failure is `.failing`.
struct AutomationHealthIssue: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable {
        case overdue
        case failing
        /// The bundled tick isn't running (Login Items "Allow in the
        /// Background" was turned off or never approved) — every schedule
        /// is affected the same way, so this collapses to ONE issue rather
        /// than one per schedule.
        case tickerDisabled
    }

    /// Stable per-agent id (the LaunchAgent label) so SwiftUI keeps row identity.
    var id: String { label }
    let label: String
    let displayName: String
    let kind: Kind
    /// True for the global all-profiles managed agents — the banner labels these
    /// as fleet-wide so a fresh per-profile operator doesn't read a managed
    /// backup/collect as their own workspace's. Defaults false for callers that
    /// don't distinguish (e.g. the overdue-digest fact builder).
    let isMulti: Bool
    /// Owning profile slug for a per-profile (non-multi) agent; "" for a
    /// multi (fleet-wide) agent, which belongs to no single profile. Threaded
    /// from `LaunchAgentService.ScheduleHealthInput.profile` so a fleet-wide
    /// digest (e.g. the headless overdue digest, which spans every profile)
    /// can attribute each listed schedule correctly instead of borrowing
    /// whichever profile happened to send the card.
    let profile: String
    /// When the schedule should have last fired (`.overdue`) — nil is not
    /// expected for a produced issue but kept optional for the model's purity.
    let expectedFire: Date?
    /// When the last recorded run finished, if any (`.failing`, or last success).
    let lastRunFinishedAt: Date?
    /// The failing run's process exit code, when its status record carried a
    /// numeric one. Lets the row explain WHY (401 / 403 / 429 / network) via
    /// `CLIBridge.explainExit` instead of only "reported failure". nil for
    /// `.overdue` (nothing ran, so there is no code) and for older status
    /// records written without one.
    let lastRunExitCode: Int32?

    init(
        label: String,
        displayName: String,
        kind: Kind,
        isMulti: Bool = false,
        profile: String = "",
        expectedFire: Date?,
        lastRunFinishedAt: Date?,
        lastRunExitCode: Int32? = nil
    ) {
        self.label = label
        self.displayName = displayName
        self.kind = kind
        self.isMulti = isMulti
        self.profile = profile
        self.expectedFire = expectedFire
        self.lastRunFinishedAt = lastRunFinishedAt
        self.lastRunExitCode = lastRunExitCode
    }

    /// True when `label` belongs to the reserved managed-automation label set
    /// (`ManagedAutomation.owns`). Only managed rows get the health card's
    /// one-click "Run now" — a hand-built agent's label was never reserved
    /// by the managed policy, so kickstarting it here would be surprising;
    /// that agent's own "Run now" lives on the Schedules screen instead.
    var isManagedAgent: Bool {
        ManagedAutomation.owns(label)
    }
}

/// Pure evaluator for the scheduled-run dead-man switch. Given the raw
/// per-schedule inputs, returns the issues an operator needs to see. No I/O,
/// no launchctl, no real LaunchAgents dir — unit-tested directly.
enum AutomationHealth {

    /// Grace after the expected fire before a run is called overdue. Scheduled
    /// runs take a few minutes; 60 min absorbs launchd jitter, a slow collect,
    /// and clock skew without hiding a genuinely-missed run.
    static let graceSeconds: TimeInterval = 60 * 60

    /// Synthetic label for the collapsed `.tickerDisabled` issue — the ticker
    /// is one bundled agent, not one of the schedules it evaluates.
    static let tickerLabel = "\(LaunchAgentWriter.labelPrefix).tick"

    /// Evaluate one probe pass. `now` is injected for deterministic tests.
    ///
    /// When the ticker requires Login Items approval or was never registered,
    /// no per-schedule state can be trusted (nothing is firing), so this
    /// short-circuits to ONE `.tickerDisabled` issue instead of every
    /// schedule reading `.overdue`. `.unavailable` (a dev build with no
    /// bundled plist) is NOT treated as disabled — registration simply
    /// doesn't apply there, and the per-schedule evaluation still runs.
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
        tickerStatus: TickerStatus = .enabled,
        now: Date = Date()
    ) -> [AutomationHealthIssue] {
        if tickerStatus == .requiresApproval || tickerStatus == .notRegistered {
            return [AutomationHealthIssue(
                label: tickerLabel,
                displayName: "Background item disabled",
                kind: .tickerDisabled,
                isMulti: true,
                profile: "",
                expectedFire: nil,
                lastRunFinishedAt: nil
            )]
        }
        return inputs.compactMap { input in
            guard input.enabled else { return nil }

            if let expected = input.expectedFire,
               now.timeIntervalSince(expected) >= graceSeconds,
               !ranAtOrAfter(input.lastRunFinishedAt, expected) {
                return AutomationHealthIssue(
                    label: input.label,
                    displayName: input.displayName,
                    kind: .overdue,
                    isMulti: input.isMulti,
                    profile: input.profile,
                    expectedFire: expected,
                    lastRunFinishedAt: input.lastRunFinishedAt
                )
            }

            if input.lastRunSuccess == false {
                return AutomationHealthIssue(
                    label: input.label,
                    displayName: input.displayName,
                    kind: .failing,
                    isMulti: input.isMulti,
                    profile: input.profile,
                    expectedFire: input.expectedFire,
                    lastRunFinishedAt: input.lastRunFinishedAt,
                    lastRunExitCode: input.lastRunExitCode
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

    /// Per-kind data-freshness issues for the ACTIVE profile. Separate from
    /// `issues` because they answer a different question (did the data land?
    /// vs did the schedule fire?) and because they are profile-scoped where a
    /// managed schedule may be fleet-wide.
    var freshnessIssues: [DataFreshnessIssue] = []

    /// True while an automatic re-collect is in flight, so the banner can say
    /// so instead of repeating the problem the app is already fixing.
    var isRemediating = false
}

// MARK: - Managed automation wiring

extension WorkspaceStore {

    /// Current automation-health issues (overdue / failing schedules). Reads
    /// the shared observable so any view that references it re-renders on change.
    var automationHealthIssues: [AutomationHealthIssue] {
        AutomationHealthModel.shared.issues
    }

    /// Whether the ticker should be registered: managed automation is on, or
    /// there's at least one hand-built schedule to fire.
    nonisolated static func wantsTicker(policy: AutomationPolicy, hasHandBuilt: Bool) -> Bool {
        policy.isManaged || hasHandBuilt
    }

    /// The policy changed, or the app launched: make Login Items agree with
    /// it. Registered when anything is scheduled; unregistered when nothing
    /// is. Called from the root view's `.task` at launch AND from the
    /// Automation screen whenever the policy changes, so enabling "Manage
    /// automation" (or adding a hand-built schedule) takes effect immediately
    /// instead of waiting for the next app launch.
    func applyAutomationPolicy() async {
        guard !demoMode else { return }
        if let result = ScheduleImport.runIfNeeded(), !result.managedLabels.isEmpty {
            _ = LaunchAgentService.archiveAndRemove(
                labels: result.managedLabels, includingManaged: true)
        }
        let wantsTicker = Self.wantsTicker(
            policy: AutomationPolicy.current(), hasHandBuilt: !ScheduleStore().load().isEmpty)
        do {
            if wantsTicker {
                try tickerRegistrar.register()
            } else {
                try tickerRegistrar.unregister()
            }
        } catch {
            AppLogger.schedule.error(
                """
                ticker \(wantsTicker ? "register" : "unregister", privacy: .public) failed: \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
        tickerStatus = tickerRegistrar.status
        // The policy/store change above can change what schedules exist and
        // what "should have fired" means — recompute on the same chain so
        // both the schedule list and the dead-man banner reflect it at once.
        reloadFromDisk()
        await refreshAutomationHealth()
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
        let schedules = self.schedules
        let tickerStatus = self.tickerStatus
        // Scan + evaluate off the main actor; both are pure file reads. Scope to
        // THIS profile's agents plus the global managed (isMulti) agents so a
        // DIFFERENT profile's hand-built schedule can't bleed onto this Overview.
        let issues = await Task.detached(priority: .utility) {
            let inputs = LaunchAgentService.filterHealthInputs(
                LaunchAgentService.healthInputs(schedules: schedules, statusProfile: profile),
                forProfile: profile)
            return AutomationHealth.evaluate(inputs: inputs, tickerStatus: tickerStatus)
        }.value
        AutomationHealthModel.shared.issues = issues

        await maybeNotifyOverdue(issues: issues, profile: profile)
        await refreshDataFreshness()
    }

    // MARK: - Data freshness (per-kind)

    /// Current per-kind freshness issues. Reads the shared observable so any
    /// view referencing it re-renders on change.
    var dataFreshnessIssues: [DataFreshnessIssue] {
        AutomationHealthModel.shared.freshnessIssues
    }

    var isRemediatingFreshness: Bool {
        AutomationHealthModel.shared.isRemediating
    }

    /// Re-evaluate per-kind freshness for the active profile from the state
    /// files `ReportEngine.collect` writes, then publish to the shared model.
    ///
    /// Runs on the same chain as `refreshAutomationHealth` (launch, reconcile,
    /// foreground) so a kind that quietly stopped landing surfaces without the
    /// operator visiting the screen that reads it.
    func refreshDataFreshness() async {
        guard !demoMode else {
            AutomationHealthModel.shared.freshnessIssues = []
            return
        }
        let profile = self.profile
        let issues = await Task.detached(priority: .utility) {
            Self.evaluateFreshness(profile: profile)
        }.value
        AutomationHealthModel.shared.freshnessIssues = issues
    }

    /// Pure-ish freshness read: state dir → states → issues. `nonisolated` so
    /// the file reads happen off the main actor.
    nonisolated static func evaluateFreshness(
        profile: String,
        now: Date = Date()
    ) -> [DataFreshnessIssue] {
        guard ProfileService.isValid(profile),
              let stateDir = try? WorkspacePaths.stateDir(for: profile) else { return [] }
        let store = StateFileStore(directory: stateDir)
        let skipExpensive = UserDefaults.standard.bool(forKey: "skipExpensiveCollections")
        let kinds = expectedKinds(
            skipExpensive: skipExpensive,
            authMethod: ProfileAuthMethod.resolve(profile: profile)
        )
        let states = store.collectionStates(for: kinds)
        // "Has this workspace ever collected?" — without it every kind on a
        // brand-new workspace reports as never-landed.
        let hasCollectedBefore = states.contains { $0.lastSuccess != nil }
        return DataFreshnessHealth.evaluate(
            states: states, hasCollectedBefore: hasCollectedBefore, now: now
        )
    }

    /// Which kinds this profile is expected to collect, and so which may be
    /// reported as failing or stale.
    ///
    /// Two exclusions, both about not alarming on an absence that is intended:
    /// the Settings toggle makes the four per-device kinds deliberately absent
    /// (the false-alarm class `FreshnessChipRow` already guards), and a Jamf
    /// Pro instance profile can never serve the Platform-only kinds. The
    /// second is applied regardless of the `.fail` counters on disk: a
    /// workspace that ran for months before the collect-side skip has a
    /// standing pile of them, and reading those back is exactly what kept the
    /// banner red.
    nonisolated static func expectedKinds(
        skipExpensive: Bool,
        authMethod: String?
    ) -> [String] {
        let skipsPlatform = ReportEngine.nonPlatformAuthMethod(authMethod) != nil
        return ReportEngine.knownCollectKinds.filter { kind in
            if skipExpensive, ReportEngine.expensivePerDeviceKinds.contains(kind) {
                return false
            }
            return !(skipsPlatform && ReportEngine.platformOnlyKinds.contains(kind))
        }
    }

    // MARK: - Manual collect

    /// The health strip's "Collect now". Force-collects the tiers behind the
    /// current freshness issues and re-evaluates, so the strip answers for the
    /// run that just happened instead of holding yesterday's verdict.
    ///
    /// Unlike `remediateStaleDataIfNeeded` this applies no hourly rate limit
    /// and no exit-2/exit-8 exclusion: a person clicking has usually just
    /// fixed the credentials or the profile that made an automatic retry
    /// pointless, and the click must not be a silent no-op.
    func collectFailingNow() async {
        guard !demoMode else { return }
        guard canRefresh(profileSlug: profile) else {
            // Practically unreachable — freshness only evaluates for a valid
            // profile — but a button click must never be a silent no-op.
            toast = Toast(message: "Collect is unavailable for this profile.", style: .info)
            return
        }
        let tiers = Self.manualCollectTiers(AutomationHealthModel.shared.freshnessIssues)
        AutomationHealthModel.shared.isRemediating = true
        defer { AutomationHealthModel.shared.isRemediating = false }
        // runTierRefresh owns the force-collect, the globalStatus line, the
        // completion toast, and (since 2.7.0) the freshness re-evaluation.
        await runTierRefresh(tiers)
    }

    /// Tiers for the manual collect: those behind the current issues, or every
    /// tier when there are none — the button is then a plain "collect
    /// everything", which is what a person clicking a health strip expects.
    nonisolated static func manualCollectTiers(
        _ issues: [DataFreshnessIssue]
    ) -> Set<CollectionTier> {
        let tiers = DataFreshnessHealth.tiersToRemediate(issues)
        return tiers.isEmpty ? Set(CollectionTier.allCases) : tiers
    }

    // MARK: - Self-remediation

    /// Marker for the automatic re-collect. `DayMarker` is a one-line string
    /// marker; stamping an HOUR key (`2026-08-25T14`) rather than a day key
    /// gives once-per-hour rate limiting with no new persistence code, and it
    /// survives relaunch — so quitting and reopening cannot be used (by an
    /// impatient operator or a crash loop) to hammer an on-prem server.
    private static let remediationMarker = DayMarker(name: "freshness-remediation")

    nonisolated static let hourKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH"
        return f
    }()

    /// Attempt one automatic re-collect of the tiers that have failing or
    /// stale kinds, then re-evaluate.
    ///
    /// Deliberately narrow:
    /// - only when the app is open and the operator can see the banner,
    /// - at most once an hour per profile,
    /// - only the tiers that actually have issues,
    /// - `force: false`, so the per-kind cadence filter collects exactly the
    ///   kinds that are behind and skips the healthy ones in the same tier.
    ///
    /// Returns true when a collect was attempted (not whether it fixed
    /// anything — the re-evaluation that follows is the real answer).
    @discardableResult
    func remediateStaleDataIfNeeded() async -> Bool {
        guard !demoMode else { return false }
        let issues = AutomationHealthModel.shared.freshnessIssues
        guard !issues.isEmpty else { return false }
        let profile = self.profile
        guard ProfileService.isValid(profile),
              let workspace = ProfileService.workspaceURL(for: profile) else { return false }

        let hourKey = Self.hourKeyFormatter.string(from: Date())
        guard Self.remediationMarker.lastStampedDay(in: workspace) != hourKey else { return false }
        // Claim the hour BEFORE the await so a second foreground event during a
        // slow collect cannot start a parallel one.
        Self.remediationMarker.stamp(day: hourKey, in: workspace)

        // Kinds whose last failure was a usage/credentials-gate error (jamf-cli
        // exit 2) cannot be fixed by retrying — filtered before tier targeting,
        // but left in `issues`/the banner so the operator still sees them.
        let remediable = Self.excludingPermanentUsageFailures(issues, profile: profile)
        let tiers = DataFreshnessHealth.tiersToRemediate(remediable)
        AutomationHealthModel.shared.isRemediating = true
        defer { AutomationHealthModel.shared.isRemediating = false }

        AppLogger.collect.notice(
            """
            Auto-remediating \(remediable.count, privacy: .public) stale/failing kind(s) \
            for \(profile, privacy: .public) — tiers \
            \(tiers.map(\.rawValue).sorted().joined(separator: ","), privacy: .public)
            """
        )
        await Self.remediateOne(profile: profile, tiers: tiers)
        await refreshDataFreshness()
        return true
    }

    /// Drop issues whose kind's last failure exit code makes retry pointless:
    /// `exitCodeUsage` (2, a usage/credentials gate — e.g. jamf-cli 1.24–1.27 on
    /// `pro report security`) and `exitCodeRefusedByPolicy` (8, 1.28+ — outside
    /// the profile's published API). Only `tiersToRemediate`'s input narrows;
    /// `issues` — and so the banner — is untouched, the operator still sees them.
    nonisolated static func excludingPermanentUsageFailures(
        _ issues: [DataFreshnessIssue], profile: String
    ) -> [DataFreshnessIssue] {
        guard ProfileService.isValid(profile),
              let stateDir = try? WorkspacePaths.stateDir(for: profile) else { return issues }
        let store = StateFileStore(directory: stateDir)
        let permanent = issues.filter {
            let code = store.lastFailureExitCode(for: $0.snapshotKind)
            return code == CLIBridge.exitCodeUsage
                || code == CLIBridge.exitCodeRefusedByPolicy
        }
        guard !permanent.isEmpty else { return issues }
        AppLogger.collect.notice(
            """
            Skipping remediation for \(permanent.count, privacy: .public) kind(s) with a \
            permanent usage/credentials-gate or policy-refusal failure: \
            \(permanent.map(\.snapshotKind).sorted().joined(separator: ","), privacy: .public)
            """
        )
        let skip = Set(permanent.map(\.snapshotKind))
        return issues.filter { !skip.contains($0.snapshotKind) }
    }

    /// Per-tier collect closure used by `remediateOne`. Matches a one-tier
    /// slice of `CollectRouter.run`'s signature; tests inject a spy.
    typealias RemediationCollector = @Sendable (
        _ profile: String,
        _ tiers: Set<CollectionTier>,
        _ config: ReportConfig?
    ) async throws -> Void

    nonisolated static func remediateOne(
        profile: String,
        tiers: Set<CollectionTier>,
        collect: RemediationCollector = defaultRemediationCollector
    ) async {
        let config: ReportConfig? = {
            guard let url = ProfileService.workspaceURL(for: profile)?
                .appendingPathComponent("config.yaml"),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try? ConfigLoader.load(from: url)
        }()
        // One collect call PER TIER, never the full set at once: passing all
        // three tiers together equals CollectionTier.allCases, which trips
        // ReportEngine.collect's once-per-day FULL-collect guard and silently
        // no-ops the remediation.
        for tier in tiers.sorted(by: { $0.rawValue < $1.rawValue }) {
            do {
                try await collect(profile, [tier], config)
            } catch {
                // A failed remediation is not silent: the failure counters advanced
                // inside collect, so the next evaluation reports a HIGHER count and
                // the banner escalates rather than resetting.
                AppLogger.collect.warning(
                    """
                    Auto-remediation collect failed for \(profile, privacy: .public) \
                    tier \(tier.rawValue, privacy: .public): \
                    \(error.localizedDescription, privacy: .private)
                    """
                )
            }
        }
    }

    nonisolated static let defaultRemediationCollector: RemediationCollector = {
        profile, tiers, config in
        try await CollectRouter.run(
            profile: profile,
            tiers: tiers,
            skipExpensive: false,
            force: false,
            config: config,
            onLine: CLIBridge.bufferingOnLine
        )
    }

    /// One-click "Run now" for a failing/overdue managed row on the
    /// Automation Health card. Spawns `JamfReports --tick --now <label>`
    /// (`TickRunner.spawnNow`) so the run records under its real label.
    /// Returns whether the spawn itself was accepted — NOT whether the
    /// collect/generate it triggers ultimately succeeds, since that
    /// finishes asynchronously.
    ///
    /// No dedicated re-eval timer here: `refreshAutomationHealth` already
    /// runs on the next reconcile, app-foreground (`willBecomeActive`), and
    /// manual reconcile, any of which will pick up the kicked-off job's
    /// status file once it finishes and clear the row.
    func runNowFromHealthRow(label: String) async -> Bool {
        await TickRunner.spawnNow(label: label, wait: false) == 0
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
    /// schedule (owning profile + display name → expected-fire date) — the
    /// evaluation is fleet-wide, so each entry names its own profile rather
    /// than the one that happened to send the card; an `isMulti` entry is
    /// fleet-wide by construction and is labeled as such instead of
    /// attributed to any single profile. `minimal` collapses to a Profile
    /// fact plus a single count with no schedule names or dates — the
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
            let name: String
            if issue.isMulti {
                // Fleet-wide by construction — same framing OverviewView uses
                // for its banner, so the two never disagree on wording.
                name = "Managed automation (all profiles) — \(fleetWideDisplayName(issue.displayName))"
            } else if !issue.profile.isEmpty {
                name = "\(issue.profile) — \(issue.displayName)"
            } else {
                name = issue.displayName
            }
            return WebhookNotifier.Fact(
                label: name,
                value: issue.expectedFire.map {
                    "expected \(ISO8601DateFormatter().string(from: $0)); no run recorded"
                } ?? "no run recorded"
            )
        }
    }

    /// Strip a leading "Managed " from a managed agent's display name so the
    /// fleet-wide framing reads "Managed automation … — Backup …" rather than
    /// the redundant "… — Managed Backup …". Shared with `OverviewView`'s
    /// banner so the two surfaces can't drift on wording.
    nonisolated static func fleetWideDisplayName(_ displayName: String) -> String {
        displayName.hasPrefix("Managed ")
            ? String(displayName.dropFirst("Managed ".count))
            : displayName
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
    /// day per app run, no matter how often the app is focused. Across app
    /// relaunches the per-kind cadence filter in `ReportEngine.collect` is the
    /// real dedupe (this call's tiers are never the full set, so the
    /// once-per-day FULL-collect guard never applies here); this flag just
    /// avoids re-statting every profile on each `willBecomeActive`.
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
    /// happened yet. Passes `force: false`, so the per-kind cadence filter in
    /// `ReportEngine.collect` no-ops a kind that already ran today.
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
                force: false,  // per-kind cadence filter: no-op if this kind already ran today
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
