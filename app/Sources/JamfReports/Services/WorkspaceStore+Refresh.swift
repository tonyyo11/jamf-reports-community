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
    private static var periodicRecheckKey: UInt8 = 0

    /// True while the coordinator's own refresh collect runs for `profile`. Reads the
    /// existing coordinator only, so asking never creates one.
    func coordinatorIsCollecting(for profile: String) -> Bool {
        guard let existing = objc_getAssociatedObject(self, &WorkspaceStore.coordinatorKey)
            as? RefreshCoordinator else { return false }
        return CollectionTier.allCases.contains {
            existing.isRefreshing(profile: profile, tier: $0)
        }
    }

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
    nonisolated static let heavyTierStaleDays = 2

    /// Populate `staleHeavyTiers` with the .inventory / .scan tiers holding an
    /// expected kind whose newest snapshot is older than `heavyTierStaleDays`.
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
        let jamfCLIVersion = self.jamfCLIVersion
        let resolveAuth = resolveAuthMethod
        let threshold = TimeInterval(Self.heavyTierStaleDays) * 86_400
        let (stale, noData) = await Task.detached(priority: .utility) {
            let expected = Self.expectedKinds(
                profile: activeProfile, jamfCLIVersion: jamfCLIVersion,
                auth: resolveAuth(activeProfile))
            let stale = Self.staleTiers(profile: activeProfile, olderThan: threshold,
                                        expectedKinds: expected)
            return (stale, Self.tiersWithNoData(profile: activeProfile, among: stale,
                                                expectedKinds: expected, olderThan: threshold))
        }.value
        // Profile may have switched while the probe ran off-actor.
        guard profile == activeProfile else { return }
        staleHeavyTiers = stale
        heavyTiersWithNoData = noData
    }

    /// Collect the currently-stale heavy tiers, then re-probe the prompt from
    /// disk. Surfaces progress through `globalStatus` and a completion toast.
    /// `collect` is injectable for tests, like `runTierRefresh`'s.
    func runHeavyTierRefresh(
        collect: @Sendable (String, Set<CollectionTier>,
                            @escaping @Sendable (CLIBridge.LogLine) -> Void)
            async throws -> Int32 = { profile, tiers, onLine in
            try await CLIBridge().collect(
                profile: profile, tiers: tiers, force: true, onLine: onLine
            )
        }
    ) async {
        let tiers = staleHeavyTiers
        guard !tiers.isEmpty, canRefresh(profileSlug: profile) else { return }
        guard !manualCollectMustWait() else { return }
        let activeProfile = profile
        let labels = tiers.map(\.displayName).joined(separator: " + ")
        beginCollect(
            for: activeProfile, status: "refreshing \(labels) data · profile=\(activeProfile)")
        defer { endCollect(for: activeProfile) }
        let honesty = CollectHonestyWatcher()
        let outcome: Toast
        do {
            let (exit, recorded) = try await Self.recordingCollect(
                profile: activeProfile, honesty: honesty
            ) { onLine in
                try await collect(activeProfile, Set(tiers), onLine)
            }
            AppLogger.event(.collect, exit == 0 ? .notice : .error,
                            "heavy-tier refresh \(exit == 0 ? "completed" : "exited \(exit)"): \(activeProfile)")
            outcome = Self.refreshToast(
                "\(labels) data refreshed", exit: exit, incomplete: honesty.incomplete,
                recorded: recorded)
        } catch {
            outcome = Self.collectFailureToast(error, operation: "Refresh")
        }
        // Re-probe rather than clear: exit 0 means the run finished, not that each
        // tier's probe kind landed, so clearing on exit 0 hid the prompt for a tier
        // whose probe kind failed while other kinds landed.
        await checkHeavyTierStaleness()
        // Success or failure, the health strip must describe the run that just
        // happened — before 2.7.0 it kept its launch-time verdict until the app
        // was backgrounded, so a manual refresh appeared to change nothing.
        await refreshDataFreshness()
        // Same ordering as `runTierRefresh`: the caller's button reads "Refreshing…"
        // until this returns.
        toast = outcome
    }

    /// Force-collect the given `tiers` and surface progress through `globalStatus`
    /// and a completion/failure toast. No-ops when `tiers` is empty or `canRefresh`
    /// is false. Modelled on `runHeavyTierRefresh`.
    func runTierRefresh(
        _ tiers: Set<CollectionTier>,
        collect: @Sendable (String, Set<CollectionTier>,
                            @escaping @Sendable (CLIBridge.LogLine) -> Void)
            async throws -> Int32 = { profile, tiers, onLine in
            try await CLIBridge().collect(
                profile: profile, tiers: tiers, force: true, onLine: onLine
            )
        }
    ) async {
        guard !tiers.isEmpty, canRefresh(profileSlug: profile) else { return }
        guard !manualCollectMustWait() else { return }
        let activeProfile = profile
        beginCollect(for: activeProfile, status: "refreshing data · profile=\(activeProfile)")
        defer { endCollect(for: activeProfile) }
        let honesty = CollectHonestyWatcher()
        let outcome: Toast
        do {
            let (exit, recorded) = try await Self.recordingCollect(
                profile: activeProfile, honesty: honesty
            ) { onLine in
                try await collect(activeProfile, tiers, onLine)
            }
            AppLogger.event(.collect, exit == 0 ? .notice : .error,
                            "refresh \(exit == 0 ? "completed" : "exited \(exit)"): \(activeProfile)")
            outcome = Self.refreshToast(
                "Data refreshed", exit: exit, incomplete: honesty.incomplete, recorded: recorded)
        } catch {
            outcome = Self.collectFailureToast(error, operation: "Refresh")
        }
        // The Overview scan prompt reads `staleHeavyTiers`, which only the prompt's
        // own button cleared — so a toolbar refresh that collected every tier left
        // it on its launch-time verdict (2.8.0 field pass). Re-probe from disk.
        await checkHeavyTierStaleness()
        await refreshDataFreshness()
        // Callers show "Collecting…" until this returns; a toast posted before the
        // re-probes read "Data refreshed" beside a button still collecting.
        toast = outcome
    }

    /// First full collect for a never-fetched workspace (#181) — the
    /// StaleDataBanner "Collect now" action. Runs every tier so the user gets
    /// a complete starting point (dashboards + the first trend data point)
    /// from one click, then re-probes heavy-tier staleness so the prompt
    /// clears honestly. Failures surface as a toast instead of the silent
    /// RefreshCoordinator backoff that left issue #181's reporter stranded.
    func runFirstCollect(
        collect: @Sendable (String, @escaping @Sendable (CLIBridge.LogLine) -> Void)
            async throws -> Int32 = { profile, onLine in
            try await CLIBridge().collect(
                profile: profile, tiers: Set(CollectionTier.allCases), force: true,
                onLine: onLine
            )
        }
    ) async {
        guard canRefresh(profileSlug: profile) else {
            // Practically unreachable (the banner is suppressed in demo mode),
            // but a button click must never be a silent no-op.
            toast = Toast(message: "Collect is unavailable for this profile.", style: .info)
            return
        }
        guard !manualCollectMustWait() else { return }
        let activeProfile = profile
        beginCollect(
            for: activeProfile, status: "collecting jamf-cli data · profile=\(activeProfile)")
        defer { endCollect(for: activeProfile) }
        let honesty = CollectHonestyWatcher()
        let outcome: Toast
        do {
            let (exit, recorded) = try await Self.recordingCollect(
                profile: activeProfile, honesty: honesty
            ) { onLine in
                try await collect(activeProfile, onLine)
            }
            outcome = Self.firstCollectToast(
                exitCode: exit, runRecorded: recorded, incomplete: honesty.incomplete)
        } catch {
            outcome = Self.collectFailureToast(error, operation: "Collect")
        }
        await checkHeavyTierStaleness()
        await refreshDataFreshness()
        // Same ordering as `runTierRefresh`: the banner reads "Collecting…" until this returns.
        toast = outcome
    }

    // MARK: One collect at a time for manual collects

    /// True, after posting the toast, when a manual collect must not start: another live
    /// process — the bundled `--tick` agent — holds the tick lock (#226 5c), or a collect is
    /// already running in this app, for any profile. `CLIBridge.collect` would refuse the
    /// collect anyway; asking first keeps a refused button from touching any state.
    func manualCollectMustWait() -> Bool {
        let refusal = CLIBridge.collectRefusal()
            ?? (isAnyCollectInFlight ? CLIBridgeError.collectInProgress : nil)
        guard let refusal else { return false }
        AppLogger.collect.notice(
            "Manual collect refused: \(refusal.localizedDescription, privacy: .public)")
        toast = Self.collectFailureToast(refusal, operation: "Refresh")
        return true
    }

    /// The toast for a GUI collect that threw. A refusal — a tick holding the lock, or another
    /// collect running here — is not a failure, so it is not shown as one.
    nonisolated static func collectFailureToast(_ error: Error, operation: String) -> Toast {
        let refused = CLIBridgeError.isCollectRefusal(error)
        return Toast(message: CLIBridge.explainOperationError(error, operation: operation),
                     style: refused ? .info : .danger)
    }

    /// Where a GUI collect's warning lines can be read: Run History only for a run a
    /// `ScheduledRunRecorder` wrote, otherwise the in-app log (`CLIBridge.bufferingOnLine`).
    enum WarningsDestination: Sendable {
        case runHistory, settingsLogging

        var pointer: String {
            switch self {
            case .runHistory: "see Run History"
            case .settingsLogging: "see Settings › Logging"
            }
        }
    }

    /// The toast for a GUI collect that exited 0, which does not mean every source landed:
    /// `incomplete` (`CollectHonestyWatcher`) is what Run History reads as Partial.
    nonisolated static func collectCompletedToast(
        _ message: String, incomplete: Bool, warningsAt: WarningsDestination
    ) -> Toast {
        guard incomplete else { return Toast(message: message, style: .success) }
        return Toast(
            message: "Refresh finished with warnings — \(warningsAt.pointer)", style: .warning)
    }

    /// `sink`, after feeding each run line to `honesty`.
    nonisolated static func observing(
        _ honesty: CollectHonestyWatcher,
        then sink: @escaping @Sendable (CLIBridge.LogLine) -> Void
    ) -> @Sendable (CLIBridge.LogLine) -> Void {
        { line in
            honesty.observe(line.text)
            sink(line)
        }
    }

    /// Run History label for every collect the app starts itself: the first collect, a Refresh
    /// button, a heavy-tier prompt and the banner's Collect now. One reserved label with no
    /// profile part, so it can never be a schedule's (`LaunchAgentWriter.label(for:)` always
    /// writes `<prefix>.<profile>.<slug>` and `ManagedAutomation` `<prefix>.multi.<slug>`), and
    /// no schedule's "Last Run", overdue check or retry reads its `_status.json`. Must carry the
    /// LaunchAgent label prefix or `ScheduledRunRecorder.init` rejects it and the run goes
    /// unrecorded.
    nonisolated static var appCollectRunLabel: String {
        "\(LaunchAgentWriter.labelPrefix).manual-collect"
    }

    /// App-started collect records kept per workspace. Like `TickFailureLog.keptRecords`, a cap
    /// so a button pressed often cannot push schedule runs out of the recorder's window.
    nonisolated static let keptAppCollectRuns = 20

    /// Runs a GUI collect with its lines fed to the in-app log, `honesty` and a Run History
    /// record under `appCollectRunLabel`, which `runFirstCollect` has always written.
    /// `recorded` is false when the record could not be opened: the run still goes ahead and
    /// the toast then names the in-app log. A collect that is refused ends no record,
    /// since nothing ran. Main-actor like its callers, so their non-`Sendable` collect closures
    /// stay in one isolation domain.
    @MainActor
    static func recordingCollect(
        profile: String,
        honesty: CollectHonestyWatcher,
        _ run: (@escaping @Sendable (CLIBridge.LogLine) -> Void) async throws -> Int32
    ) async throws -> (exit: Int32, recorded: Bool) {
        if let logs = try? WorkspacePaths.runHistoryDir(for: profile) {
            ScheduledRunRecorder.pruneRunLogs(
                in: logs, keep: keptAppCollectRuns - 1, label: appCollectRunLabel)
        }
        let recorder = ProfileService.workspaceURL(for: profile).flatMap {
            ScheduledRunRecorder(workspace: $0, label: appCollectRunLabel)
        }
        if recorder == nil {
            AppLogger.cli.warning(
                "Collect run recorder unavailable — this run will not appear in Run History"
            )
        }
        do {
            let exit = try await run(observing(honesty, then: { line in
                CLIBridge.bufferingOnLine(line)
                recorder?.record(line.text)
            }))
            recorder?.finish(exitCode: exit)
            return (exit, recorder != nil)
        } catch {
            if CLIBridgeError.isCollectRefusal(error) {
                recorder?.discard()
            } else {
                recorder?.record("[error] \(error.localizedDescription)")
                recorder?.finish(exitCode: 1)
            }
            throw error
        }
    }

    /// The toast for a finished Refresh: the success or warnings text on exit 0, otherwise the
    /// exit code and where the run's lines can be read.
    nonisolated static func refreshToast(
        _ message: String, exit: Int32, incomplete: Bool, recorded: Bool
    ) -> Toast {
        let destination: WarningsDestination = recorded ? .runHistory : .settingsLogging
        guard exit == 0 else {
            return Toast(
                message: "Refresh finished with exit \(exit) — \(destination.pointer)",
                style: .danger)
        }
        return collectCompletedToast(message, incomplete: incomplete, warningsAt: destination)
    }

    /// Exit-code triage for the first-collect toast. Only exit 3 blames
    /// credentials — exit 1 is usually partial per-kind failures, and blaming
    /// auth sent the #181 field tester to the wrong page.
    nonisolated static func firstCollectToast(
        exitCode: Int32, runRecorded: Bool = true, incomplete: Bool = false
    ) -> Toast {
        if exitCode == 0 {
            // Context-neutral: this path also serves CollectNowBanner on every
            // collect-fed screen, not just the first-run flow.
            return collectCompletedToast(
                "Collection complete", incomplete: incomplete,
                warningsAt: runRecorded ? .runHistory : .settingsLogging)
        }
        if exitCode == CLIBridge.exitCodeUnauthorized {
            return Toast(
                message: "Collect failed — jamf-cli credentials expired; re-authenticate "
                    + "from Settings → Connections",
                style: .danger
            )
        }
        // Only point at Run History when this run was actually recorded;
        // otherwise the failing commands live in the app log, not a run log.
        let tail = runRecorded
            ? "see Run History for the failing commands"
            : "check the app log"
        return Toast(
            message: "Collect finished with errors (exit \(exitCode)) — \(tail)",
            style: .danger
        )
    }

    /// Run a Health Audit in the background when the cached audit snapshot is
    /// older than `heavyTierStaleDays`. Part of the launch-time freshness
    /// sweep — audit is a configuration-analysis call (no per-device
    /// enumeration), so unlike the heavy tiers it is safe to run unprompted.
    ///
    /// `autoAuditRefreshInFlight` dedups re-entry: rapid profile switches or
    /// repeated launch-task firings must not stack concurrent audit runs. The
    /// whole function is `@MainActor` and the flag is checked-then-set with no
    /// `await` between, so the guard is race-free. `audit` is injectable so
    /// tests can control timing without spawning a real subprocess.
    func autoRefreshAuditIfStale(
        audit: @Sendable (String) async throws -> Int32 = { profile in
            try await CLIBridge().audit(profile: profile, category: nil, onLine: CLIBridge.noOpOnLine)
        }
    ) async {
        guard !autoAuditRefreshInFlight else { return }
        guard canRefresh(profileSlug: profile) else { return }
        autoAuditRefreshInFlight = true
        defer { autoAuditRefreshInFlight = false }

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
            _ = try await audit(activeProfile)
        } catch {
            AppLogger.cli.warning(
                "Launch audit refresh failed: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    /// Heavy tiers holding an expected kind whose newest snapshot is older than
    /// `threshold`, or that never landed (#181: once the workspace directory
    /// exists, the prompt is the only heavy-collect affordance a fresh workspace
    /// has; a missing workspace is the Overview init banner's job). Only
    /// `expectedKinds` count, and not one whose last failure repeats on retry,
    /// so neither a kind the profile never collects nor one it cannot collect
    /// holds the prompt up. A tier with none is never stale.
    nonisolated static func staleTiers(
        profile: String,
        olderThan threshold: TimeInterval,
        expectedKinds: [String]
    ) -> [CollectionTier] {
        let exists = workspaceExists(profile: profile)
        return [CollectionTier.inventory, .scan].filter { tier in
            let stale = staleKinds(profile: profile, tier: tier, expectedKinds: expectedKinds,
                                   olderThan: threshold)
            return !stale.aged.isEmpty || (exists && !stale.neverLanded.isEmpty)
        }
    }

    /// Among `tiers`, those stale only through kinds with no snapshot at all
    /// even though the workspace collected recently — i.e. the last collect
    /// attempted them and produced no data, as opposed to never-attempted or
    /// aged-out data. Lets the prompt say "couldn't be collected" instead of
    /// the contradictory "missing" right after a successful first collect.
    nonisolated static func tiersWithNoData(
        profile: String, among tiers: [CollectionTier],
        expectedKinds: [String], olderThan threshold: TimeInterval
    ) -> Set<CollectionTier> {
        guard workspaceCollectedRecently(profile: profile) else { return [] }
        return Set(tiers.filter { tier in
            let stale = staleKinds(profile: profile, tier: tier, expectedKinds: expectedKinds,
                                   olderThan: threshold)
            return !stale.neverLanded.isEmpty && stale.aged.isEmpty
        })
    }

    /// `tier`'s expected kinds that are stale, split by why. A kind whose last
    /// failure cannot succeed on retry is left out: the health banner names it
    /// with its cause, and this prompt's button would only force the tier again.
    private nonisolated static func staleKinds(
        profile: String, tier: CollectionTier, expectedKinds: [String],
        olderThan threshold: TimeInterval
    ) -> (neverLanded: [String], aged: [String]) {
        let state = (try? WorkspacePaths.stateDir(for: profile)).map(StateFileStore.init)
        var neverLanded: [String] = []
        var aged: [String] = []
        for kind in expectedKinds where CollectionTier.tier(forReport: kind) == tier {
            if let state, lastFailureRepeatsOnRetry(kind, in: state) { continue }
            if let age = newestSnapshotAge(profile: profile, kind: kind) {
                if age >= threshold { aged.append(kind) }
            } else {
                neverLanded.append(kind)
            }
        }
        return (neverLanded, aged)
    }

    /// The kinds `profile` is expected to collect, from the inputs the health
    /// strip reads: the skip-expensive toggle, `jamf_cli.collect_skip`, the
    /// profile's auth method and the jamf-cli version (for the dashboard).
    nonisolated static func expectedKinds(
        profile: String, jamfCLIVersion: String?, auth: ProfileAuthMethod.Resolved?
    ) -> [String] {
        let config = ProfileService.workspaceURL(for: profile).flatMap {
            try? ConfigLoader.load(from: $0.appendingPathComponent("config.yaml"))
        }
        return expectedKinds(
            skipExpensive: UserDefaults.standard.bool(forKey: "skipExpensiveCollections"),
            authMethod: auth?.authMethod,
            tenantLevel: auth?.isTenantLevel == true,
            collectSkip: ReportEngine.collectSkipKinds(config?.jamfCli?.collectSkip),
            dashboardSupported: JamfCLIInstaller.supportsDashboard(jamfCLIVersion)
        )
    }

    /// True when any snapshot kind has a file newer than `interval` —
    /// evidence that a collect ran recently.
    nonisolated static func workspaceCollectedRecently(
        profile: String, within interval: TimeInterval = 86_400
    ) -> Bool {
        guard let dataDir = try? WorkspacePaths.dataDir(for: profile),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: dataDir, includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              ) else { return false }
        return entries.contains { entry in
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { return false }
            guard let age = newestSnapshotAge(profile: profile, kind: entry.lastPathComponent)
            else { return false }
            return age <= interval
        }
    }

    /// True when the profile's workspace directory exists on disk.
    nonisolated static func workspaceExists(profile: String) -> Bool {
        guard let root = ProfileService.workspaceURL(for: profile) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Age in seconds of the newest snapshot under
    /// `<workspace>/jamf-cli-data/<kind>/`, or nil when none exist. JSON, except
    /// jamf-cli's dashboard, the one kind saved as a page.
    nonisolated static func newestSnapshotAge(profile: String, kind: String) -> TimeInterval? {
        guard let dataDir = try? WorkspacePaths.dataDir(for: profile) else { return nil }
        let dir = dataDir.appendingPathComponent(kind, isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let fileExtension = kind == ReportEngine.dashboardKind ? "html" : "json"
        let newest = entries
            .filter { $0.pathExtension == fileExtension }
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
    /// Also starts the periodic re-check loop, which has its own guard.
    func registerForegroundRefresh() {
        startPeriodicRecheck()
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
                // Catch-up-on-wake: if the Mac slept through the scheduled
                // freshness run, collect today's snapshot now. Once-per-day
                // guarded; no-op unless managed freshness is on.
                await self.catchUpCollectIfNeeded()
                // Re-evaluate the dead-man switch on wake so a schedule that
                // went overdue while the app was open/asleep surfaces without
                // a relaunch. Self-guards on demo mode. This also re-evaluates
                // per-kind data freshness.
                await self.refreshAutomationHealth()
                // Then try to fix what it found. Hour-rate-limited internally,
                // so repeated app focus does not repeatedly hit the server.
                await self.remediateStaleDataIfNeeded()
            }
        }
        objc_setAssociatedObject(
            self,
            &WorkspaceStore.foregroundObserverKey,
            token,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    // MARK: Periodic re-check

    /// How often the open app re-runs the wake chain (catch-up, dead-man
    /// switch, self-remediation) without a foreground event. Each callee is
    /// day- or hour-guarded, so a shorter interval would buy nothing.
    nonisolated static let periodicRecheckInterval: TimeInterval = 30 * 60

    /// Start the periodic re-check loop, at most once per store; returns false
    /// when one already exists. The first pass waits a full interval — launch
    /// already runs the same chain, and a test that registers must not collect.
    @discardableResult
    func startPeriodicRecheck() -> Bool {
        if objc_getAssociatedObject(self, &WorkspaceStore.periodicRecheckKey) != nil {
            return false
        }
        let loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.periodicRecheckInterval))
                guard let self, !Task.isCancelled else { return }
                // The callees guard demo mode too; skipping here keeps a demo
                // session from touching the disk at all.
                guard !self.demoMode else { continue }
                await self.catchUpCollectIfNeeded()
                await self.refreshAutomationHealth()
                await self.remediateStaleDataIfNeeded()
            }
        }
        objc_setAssociatedObject(
            self,
            &WorkspaceStore.periodicRecheckKey,
            loop,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return true
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
