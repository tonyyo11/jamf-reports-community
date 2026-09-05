import Foundation

/// Owns the global "managed" LaunchAgents derived from `AutomationPolicy`
/// (v2.2.0 "set policy, not cron jobs").
///
/// Reconcile is DECLARATIVE and tightly SCOPED: it only ever installs, updates,
/// or removes agents whose label is in the reserved managed set — by **exact
/// membership**, never a prefix match. A user's hand-built multi-schedule
/// (`…multi.<their-name>`) therefore can never be removed by reconcile, even if
/// they named it `managed-freshness-backup` or similar.
///
/// The pure parts (`desiredSchedules`, `plan`, `owns`) carry the correctness
/// weight and are unit-tested; the async `reconcile` is a thin executor over
/// injectable install/remove closures so tests never touch real `launchctl`.
enum ManagedAutomation {

    // MARK: - Reserved identity

    /// The four managed agent kinds. Raw values are slug-safe and become the
    /// `<prefix>.multi.<slug>` label suffix.
    enum ManagedKind: String, CaseIterable, Sendable {
        case freshness = "managed-freshness"
        case scan      = "managed-scan"
        case reports   = "managed-reports"
        case backup    = "managed-backup"
    }

    /// Exact reserved label set: `<prefix>.multi.<slug>` for every kind.
    static var reservedLabels: Set<String> {
        Set(ManagedKind.allCases.map(label(for:)))
    }

    static func label(for kind: ManagedKind) -> String {
        "\(LaunchAgentWriter.labelPrefix).multi.\(kind.rawValue)"
    }

    /// True only when `label` is exactly one of the reserved managed labels.
    /// Deliberately not a prefix test — reconcile must never remove a user
    /// agent whose name merely starts with `managed-`.
    static func owns(_ label: String) -> Bool {
        reservedLabels.contains(label)
    }

    // MARK: - Desired specs (pure)

    /// The managed `Schedule`s the policy maps to. Empty when `isManaged` is
    /// false or when no base profile is available (nothing to manage).
    ///
    /// - Parameter baseProfile: A valid profile slug used as the multi plist's
    ///   base `--profile`. The actual run fans out over `--all-profiles`, so
    ///   the base is vestigial, but `nativeMultiWrite` requires a valid slug.
    static func desiredSchedules(
        for policy: AutomationPolicy,
        baseProfile: String?,
        executablePath: String? = Bundle.main.executableURL?.path
    ) -> [Schedule] {
        guard policy.isManaged,
              let baseProfile, ProfileService.isValid(baseProfile) else { return [] }

        var out: [Schedule] = []
        if policy.freshnessEnabled {
            out.append(makeSchedule(
                .freshness, policy: policy, baseProfile: baseProfile,
                executablePath: executablePath))
        }
        if policy.scanEnabled {
            out.append(makeSchedule(
                .scan, policy: policy, baseProfile: baseProfile,
                executablePath: executablePath))
        }
        if policy.reportsCadence != .off {
            out.append(makeSchedule(
                .reports, policy: policy, baseProfile: baseProfile,
                executablePath: executablePath))
        }
        if policy.backupsEnabled {
            out.append(makeSchedule(
                .backup, policy: policy, baseProfile: baseProfile,
                executablePath: executablePath))
        }
        return out
    }

    private static func makeSchedule(
        _ kind: ManagedKind,
        policy: AutomationPolicy,
        baseProfile: String,
        executablePath: String?
    ) -> Schedule {
        Schedule(
            name: kind.rawValue,
            profile: baseProfile,
            schedule: scheduleString(kind, policy: policy),
            cadence: cadenceWord(kind, policy: policy),
            mode: mode(kind),
            next: "—",
            last: "—",
            lastStatus: .ok,
            artifacts: [],
            enabled: true,
            launchAgentLabel: label(for: kind),
            multiTarget: MultiTarget(scope: .all, sequential: true),
            tiers: tiers(kind),
            excludedProfiles: policy.excludedProfiles,
            executablePath: executablePath
        )
    }

    /// Non-nil when the running bundle sits outside /Applications or
    /// ~/Applications. Every plist the app writes points at the copy that wrote
    /// it, so a scratch or build-folder copy pins fleet automation to itself.
    static func bundleLocationWarning(
        executablePath: String? = Bundle.main.executableURL?.path,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        guard let executablePath else { return nil }
        let allowed = ["/Applications/", home.appendingPathComponent("Applications").path + "/"]
        if allowed.contains(where: executablePath.hasPrefix) { return nil }
        let bundle = executablePath.components(separatedBy: "/Contents/").first ?? executablePath
        return "JamfReports is running from \(bundle). Scheduled runs point at whichever copy "
            + "writes them, so move the app to /Applications before turning automation on."
    }

    // MARK: - Plan (pure)

    /// A single reconcile step.
    enum Action {
        case install(Schedule)
        case remove(label: String)
    }

    /// Diff `policy`'s desired managed agents against the currently-installed
    /// schedules and produce the install/remove actions.
    ///
    /// - When `force` is false an installed managed agent whose mode + cadence +
    ///   tier signature already matches the desired spec is left alone (quiet
    ///   launches). When `force` is true every desired agent is reinstalled.
    /// - Removals are restricted to installed labels `owns(_:)` accepts, so a
    ///   user's multi-schedule is never a removal target.
    static func plan(
        for policy: AutomationPolicy,
        installed: [Schedule],
        baseProfile: String?,
        force: Bool = false,
        executablePath: String? = Bundle.main.executableURL?.path
    ) -> [Action] {
        let desired = desiredSchedules(
            for: policy, baseProfile: baseProfile, executablePath: executablePath)
        let desiredByLabel: [String: Schedule] = Dictionary(
            uniqueKeysWithValues: desired.compactMap { sched in
                LaunchAgentWriter.label(for: sched).map { ($0, sched) }
            }
        )

        // Existing managed agents only — never any user-owned label.
        let installedManaged: [String: Schedule] = Dictionary(
            installed.compactMap { sched -> (String, Schedule)? in
                guard let lbl = sched.launchAgentLabel, owns(lbl) else { return nil }
                return (lbl, sched)
            },
            uniquingKeysWith: { first, _ in first }
        )

        var actions: [Action] = []

        // Installs / updates.
        for (lbl, sched) in desiredByLabel {
            if !force, let existing = installedManaged[lbl],
               signature(existing) == signature(sched) {
                continue  // unchanged — skip the unload/reload churn.
            }
            actions.append(.install(sched))
        }

        // Removals: managed agents no longer desired (covers isManaged → off).
        for lbl in installedManaged.keys where desiredByLabel[lbl] == nil {
            actions.append(.remove(label: lbl))
        }

        // Stable order so the plan is deterministic for tests + logs.
        return actions.sorted(by: actionSort)
    }

    // MARK: - Reconcile outcomes

    /// The result of executing one reconcile action. Carries the action that was
    /// attempted, whether it succeeded, and a human-readable reason when it did not.
    struct ActionOutcome: Sendable {
        let action: Action
        let succeeded: Bool
        let failureReason: String?

        var isInstall: Bool {
            if case .install = action { return true }
            return false
        }
    }

    // MARK: - Reconcile (thin executor)

    /// Apply the policy: discover profiles, plan, and execute installs/removes.
    /// No-op-safe to call on every launch — for a user who never opted in
    /// (`isManaged == false`, no managed agents installed) the plan is empty.
    ///
    /// The `install`/`remove`/`discover`/`installed` closures default to the
    /// production implementations; tests inject spies so no real `launchctl`
    /// runs.
    ///
    /// - Parameter currentLabel: The LaunchAgent label of THIS process, when
    ///   it is itself a scheduled-run invocation (threaded from `--label`).
    ///   The action targeting this exact label — install or remove — is
    ///   routed through `installFileOnly`/`removeFileOnly` instead of the
    ///   normal closures, so reconciling never `launchctl bootout`s the job
    ///   that is currently executing this code. `nil` (the GUI's case, and
    ///   any process that isn't itself a managed agent) disables the
    ///   self-skip entirely — every action goes through the normal path.
    ///
    /// Returns per-action outcomes so callers can surface real results rather
    /// than counting planned actions. `Action` is not `Equatable` by design —
    /// callers pattern-match `outcome.action`.
    @discardableResult
    static func reconcile(
        policy: AutomationPolicy,
        force: Bool = false,
        currentLabel: String? = nil,
        discover: () -> [JamfCLIProfile] = ProfileService.discoverLocal,
        installed: () -> [Schedule] = LaunchAgentService.list,
        install: @Sendable (Schedule) async -> (Int32, String?),
        installFileOnly: @Sendable (Schedule) async -> (Int32, String?) = defaultInstallFileOnly,
        remove: @Sendable (String) async -> String?,
        removeFileOnly: @Sendable (String) async -> String? = defaultRemoveFileOnly
    ) async -> [ActionOutcome] {
        let profiles = discover()
        let excluded = Set(policy.excludedProfiles)
        let baseProfile = profiles.first { !excluded.contains($0.name) }?.name
        let actions = plan(
            for: policy, installed: installed(), baseProfile: baseProfile, force: force
        )
        var outcomes: [ActionOutcome] = []
        for action in actions {
            switch action {
            case .install(let sched):
                let isSelf = currentLabel != nil
                    && LaunchAgentWriter.label(for: sched) == currentLabel
                let (code, reason) = isSelf ? await installFileOnly(sched) : await install(sched)
                let succeeded = (code == 0)
                if !succeeded {
                    let name = sched.name
                    let detail = reason ?? "exit \(code)"
                    AppLogger.cli.error(
                        "install \(name, privacy: .public) failed: \(detail, privacy: .public)"
                    )
                } else if isSelf {
                    AppLogger.cli.info(
                        """
                        install \(sched.name, privacy: .public) wrote its own running plist \
                        file-only (no bootout/bootstrap)
                        """
                    )
                }
                outcomes.append(
                    ActionOutcome(action: action, succeeded: succeeded, failureReason: reason))
            case .remove(let label):
                let isSelf = currentLabel != nil && label == currentLabel
                let reason = isSelf ? await removeFileOnly(label) : await remove(label)
                let succeeded = (reason == nil)
                if !succeeded {
                    let detail = reason ?? "unknown error"
                    AppLogger.cli.error(
                        "remove \(label, privacy: .public) failed: \(detail, privacy: .public)"
                    )
                }
                outcomes.append(
                    ActionOutcome(action: action, succeeded: succeeded, failureReason: reason))
            }
        }
        return outcomes
    }

    /// Convenience overload with the legacy `(Int32, Void)` closure signatures,
    /// used by call sites that only need the [Action] count for backward compat.
    @discardableResult
    static func reconcile(
        policy: AutomationPolicy,
        force: Bool = false,
        currentLabel: String? = nil,
        discover: () -> [JamfCLIProfile] = ProfileService.discoverLocal,
        installed: () -> [Schedule] = LaunchAgentService.list
    ) async -> [ActionOutcome] {
        await reconcile(
            policy: policy, force: force, currentLabel: currentLabel,
            discover: discover, installed: installed,
            install: defaultInstall, remove: defaultRemove
        )
    }

    /// One-shot migration wrapper: forces a single reconcile pass when
    /// `migrationKey` hasn't been claimed yet (see `WorkspaceStore
    /// .reconcileManagedAutomation`'s doc for the RunAtLoad-migration
    /// history), and marks it claimed ONLY when every action in that forced
    /// pass succeeded (`migrationShouldComplete`). A partial failure leaves
    /// the flag unset so the NEXT launch or scheduled run retries — silently
    /// marking a failed pass "done" would strand the affected agent's plist
    /// on its old (pre-migration) settings forever.
    ///
    /// Shared by the GUI launch path and the headless `--scheduled-run` self
    /// -heal (2.6 field-incident fix: before this, a policy edit or the
    /// RunAtLoad migration only ever applied on a GUI launch, so a
    /// headless-only host could run on stale plists indefinitely).
    @discardableResult
    static func reconcileWithMigration(
        policy: AutomationPolicy,
        currentLabel: String? = nil,
        migrationKey: String = "managedRunAtLoadMigratedV1",
        defaults: UserDefaults = .standard
    ) async -> [ActionOutcome] {
        let force = !defaults.bool(forKey: migrationKey)
        let outcomes = await reconcile(policy: policy, force: force, currentLabel: currentLabel)
        if force, migrationShouldComplete(outcomes: outcomes) {
            defaults.set(true, forKey: migrationKey)
        }
        return outcomes
    }

    /// Force the next reconcile to rewrite every managed plist, by clearing the
    /// flag `reconcileWithMigration` uses to decide whether a forced pass is
    /// still owed.
    ///
    /// Needed when something outside the policy changes what a plist should
    /// contain — moving the workspace root changes `WorkingDirectory` and the
    /// run environment, but leaves mode, cadence, tiers and exclusions
    /// identical, so the signature check would call every agent unchanged and
    /// silently leave them pointing at the old location.
    ///
    /// Note the flag's name is now historical: `managedRunAtLoadMigratedV1`
    /// began as the RunAtLoad migration's one-shot marker and is now the
    /// general "a forced pass is owed" trigger. Do not narrow it back to
    /// RunAtLoad-only — a root move depends on it too.
    static func invalidateManagedPlists(
        migrationKey: String = "managedRunAtLoadMigratedV1",
        defaults: UserDefaults = .standard
    ) {
        defaults.removeObject(forKey: migrationKey)
    }

    /// Pure decision behind `reconcileWithMigration`: the migration flag may
    /// be marked complete only when every attempted action succeeded. An
    /// empty plan (nothing needed doing) trivially satisfies this.
    static func migrationShouldComplete(outcomes: [ActionOutcome]) -> Bool {
        outcomes.allSatisfy(\.succeeded)
    }

    /// Default install closure: captures the error reason string so the reconcile
    /// caller can surface it instead of silently substituting -1.
    static let defaultInstall: @Sendable (Schedule) async -> (Int32, String?) = { schedule in
        do {
            let code = try await CLIBridge().setupLaunchAgent(schedule, load: true) { _ in }
            return (code, code != 0 ? "launchctl exit \(code)" : nil)
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    /// File-only install: writes the plist without touching the running job
    /// (`CLIBridge.setupLaunchAgent(applyToRunningJob: false)`). Used only for
    /// the reconcile action whose label equals `currentLabel` — see
    /// `reconcile(currentLabel:)`.
    static let defaultInstallFileOnly: @Sendable (Schedule) async -> (Int32, String?) = { schedule in
        do {
            let code = try await CLIBridge().setupLaunchAgent(
                schedule, load: true, applyToRunningJob: false
            ) { _ in }
            return (code, code != 0 ? "launchctl exit \(code)" : nil)
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    /// Default remove closure: captures unload exit-code and delete errors so
    /// callers know whether the agent actually left disk.
    static let defaultRemove: @Sendable (String) async -> String? = { label in
        guard owns(label) else {
            // Defence in depth: reconcile plan should never produce this, but guard anyway.
            return "refused — label '\(label)' is not owned by managed automation"
        }
        let unloadCode = await LaunchAgentWriter.unload(label)
        if unloadCode != 0 {
            // Non-zero is expected when the agent was never loaded (e.g. disabled);
            // log at info level rather than treating it as a hard failure.
            // Non-zero from bootout is normal when the agent was never loaded;
            // treat as informational, not an error.
            AppLogger.schedule.info(
                "bootout \(label, privacy: .public) exit \(unloadCode, privacy: .public)"
            )
        }
        do {
            try LaunchAgentWriter.delete(label)
            return nil  // success
        } catch {
            return error.localizedDescription
        }
    }

    /// File-only remove: deletes the plist without `launchctl bootout` — the
    /// same self-preservation rule as `defaultInstallFileOnly`, for the
    /// (unlikely) case where the current process's own label is no longer
    /// desired mid-run.
    static let defaultRemoveFileOnly: @Sendable (String) async -> String? = { label in
        guard owns(label) else {
            return "refused — label '\(label)' is not owned by managed automation"
        }
        do {
            try LaunchAgentWriter.delete(label)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Per-kind mapping

    private static func mode(_ kind: ManagedKind) -> Schedule.RunMode {
        switch kind {
        case .freshness: return .snapshotOnly          // collect + summary.json, no workbook
        case .scan:      return .snapshotOnly          // collect heavy scan only
        case .reports:   return .jamfCLIOnly           // generate from the already-fresh cache
        case .backup:    return .backup
        }
    }

    private static func tiers(_ kind: ManagedKind) -> Set<CollectionTier>? {
        switch kind {
        case .freshness: return [.refresh, .inventory]
        case .scan:      return [.scan]
        case .reports, .backup: return nil             // these modes never collect
        }
    }

    /// Minutes each kind is offset off the shared base run time, so the four
    /// agents don't fire simultaneously against on-prem Jamf Pro.
    private static func staggerMinutes(_ kind: ManagedKind) -> Int {
        switch kind {
        case .freshness: return 0
        case .scan:      return 10
        case .reports:   return 20
        case .backup:    return 30
        }
    }

    private static func cadenceWord(_ kind: ManagedKind, policy: AutomationPolicy) -> String {
        switch kind {
        case .freshness: return "daily"
        case .scan, .backup: return "weekly"
        case .reports:
            switch policy.reportsCadence {
            case .daily:   return "daily"
            case .monthly: return "monthly"
            case .weekly, .off: return "weekly"
            }
        }
    }

    /// Cadence string in the exact shape `LaunchAgentWriter.setupCadence`
    /// parses: "Daily HH:MM" / "<Day3> HH:MM" / "Day <n> HH:MM".
    private static func scheduleString(_ kind: ManagedKind, policy: AutomationPolicy) -> String {
        let time = staggeredTime(base: policy.runTime, offsetMinutes: staggerMinutes(kind))
        switch kind {
        case .freshness:
            return "Daily \(time)"
        case .scan:
            return "\(weekdayAbbrev(policy.scanWeekday)) \(time)"
        case .backup:
            return "\(weekdayAbbrev(policy.backupsWeekday)) \(time)"
        case .reports:
            switch policy.reportsCadence {
            case .daily:
                return "Daily \(time)"
            case .monthly:
                // Matches `LaunchAgentService.formatCalendar`'s "Day N HH:mm" reader
                // output (not the ordinal form) so the signature converges instead
                // of permanently reinstalling on every reconcile. Clamped to the
                // 1...28 range `setupCadence` accepts — the retired `ordinal()`
                // clamped too, and an out-of-range policy value must keep
                // installing rather than start throwing cadenceParseError.
                let day = min(max(1, policy.reportsDayOfMonth), 28)
                return "Day \(day) \(time)"
            case .weekly, .off:
                return "\(weekdayAbbrev(policy.reportsWeekday)) \(time)"
            }
        }
    }

    // MARK: - Pure formatting helpers

    /// Add `offsetMinutes` to "HH:mm", clamped within the same day (never wraps
    /// past 23:59 — staggers are small and a wrap would reorder the agents).
    static func staggeredTime(base: String, offsetMinutes: Int) -> String {
        let parts = base.split(separator: ":").compactMap { Int($0) }
        let h = parts.count > 0 ? parts[0] : 6
        let m = parts.count > 1 ? parts[1] : 0
        let total = min(23 * 60 + 59, max(0, h * 60 + m) + offsetMinutes)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func weekdayAbbrev(_ weekday: Int) -> String {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return names[min(max(0, weekday), 6)]
    }

    /// Stable signature for the "unchanged?" check: executable + mode + cadence string +
    /// sorted tiers + sorted exclusions. `LaunchAgentService.parse` now reads
    /// `--exclude-profiles` back into `Schedule.excludedProfiles`, so an
    /// exclusions-only policy edit is detected here instead of being a no-op.
    private static func signature(_ schedule: Schedule) -> String {
        let tierCSV = (schedule.tiers ?? []).map(\.rawValue).sorted().joined(separator: ",")
        let exclCSV = (schedule.excludedProfiles ?? []).sorted().joined(separator: ",")
        return "\(schedule.executablePath ?? "")|\(schedule.mode.rawValue)|\(schedule.schedule)"
            + "|\(tierCSV)|\(exclCSV)"
    }

    private static func actionSort(_ lhs: Action, _ rhs: Action) -> Bool {
        func key(_ a: Action) -> String {
            switch a {
            case .install(let s): return "0:\(s.launchAgentLabel ?? s.name)"
            case .remove(let l):  return "1:\(l)"
            }
        }
        return key(lhs) < key(rhs)
    }
}
