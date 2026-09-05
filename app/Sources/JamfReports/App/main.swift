import ArgumentParser
import Foundation
import SwiftUI

// MARK: - Headless scheduled-run dispatch
//
// When the LaunchAgent invokes the app with --scheduled-run --profile <slug>,
// run collect + generate synchronously via a detached Task and exit without
// launching the GUI. This replaces the former jamf-cli-only ProgramArguments
// that only collected data and never ran generate.
//
// When --all-profiles is also present, discover all local profiles via
// ProfileService.discoverLocal() and run the cycle for each in sequence.

/// Emit one consolidated fleet CSV per configured `report_group` after an
/// all-profiles reports run. No-op when no groups are configured. Best-effort:
/// a failed group logs a warning and never fails the overall run. Lookback for
/// the delta columns follows the report cadence (daily 1d / weekly 7d /
/// monthly 30d).
///
/// Failures are written to a bounded `_fleet-reports/fleet-reports.log` under
/// the workspaces root (appended, truncated when > 1 MB) AND to stderr. The
/// `record` callback is kept for callers that also want the line in a
/// `ScheduledRunRecorder`, but per-profile recorders are finished by the time
/// this runs in the all-profiles path, so the log file is the durable record.
@Sendable
private func emitConsolidatedReports(record: @Sendable (String) -> Void = { _ in }) {
    let policy = AutomationPolicy.current()
    guard !policy.reportGroups.isEmpty else { return }
    let lookback: Int = {
        switch policy.reportsCadence {
        case .daily:   return 1
        case .monthly: return 30
        case .weekly, .off: return 7
        }
    }()
    let stamp = ExportNaming.timestamp()
    for group in policy.reportGroups {
        do {
            if let url = try FleetReportEmitter.emit(
                group: group, lookbackDays: lookback, timestamp: stamp
            ) {
                print("[ok] consolidated fleet report: \(url.lastPathComponent)")
            }
            if let xlsxURL = try FleetWorkbookEmitter.emit(
                group: group, lookbackDays: lookback, timestamp: stamp
            ) {
                print("[ok] consolidated fleet workbook: \(xlsxURL.lastPathComponent)")
            }
        } catch {
            let message = "[warn] consolidated report for '\(group.name)' failed: \(error.localizedDescription)"
            fputs(message + "\n", stderr)
            appendFleetLog(message)
            record(message)
        }
    }
}

/// Append one line to `_fleet-reports/fleet-reports.log` under the workspaces
/// root. Truncates the file when it exceeds 1 MB to keep it bounded.
/// Best-effort — never throws.
@Sendable
private func appendFleetLog(_ message: String) {
    let logURL = FleetReportEmitter.consolidatedDir()
        .appendingPathComponent("fleet-reports.log")
    let fm = FileManager.default
    do {
        try fm.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let line = ISO8601DateFormatter().string(from: Date()) + " " + message + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if fm.fileExists(atPath: logURL.path) {
            // Truncate if already over 1 MB before appending.
            let attrs = try? fm.attributesOfItem(atPath: logURL.path)
            let size = attrs?[.size] as? Int ?? 0
            if size > 1_048_576 {
                try data.write(to: logURL, options: .atomic)
                return
            }
            let handle = try FileHandle(forWritingTo: logURL)
            handle.seekToEndOfFile()
            // write(contentsOf:), not write(_:): the latter bridges to
            // -[NSFileHandle writeData:] and RAISES on failure, which Swift
            // cannot catch — the enclosing do/catch here looked like it covered
            // that and did not. On a synced workspace the write really can fail.
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: logURL, options: .atomic)
        }
    } catch {
        AppLogger.schedule.warning(
            "appendFleetLog: could not write fleet-reports.log: \(error.localizedDescription, privacy: .public)"
        )
    }
}

// Webhook fact assembly, the scheduled-run digest/alert senders, and the
// metric-aware strict-prior selection now live in
// `Services/ScheduledRunSignals.swift` (shared with the included CLI). This
// file's scheduled path calls `ScheduledRunSignals.notifyScheduledRun` /
// `.notifyMetricAlerts` / `.notifyScheduledRunFailure`; the fleet dead-man
// overdue digest below stays here — it has no single-run CLI meaning.

/// Headless dead-man overdue digest (2.6 "trust trio" #2). The GUI publishes
/// overdue schedules and posts a once-per-day digest at launch; a host that only
/// ever runs the LaunchAgent (GUI never opened) would otherwise get zero
/// overdue coverage. Call EXACTLY ONCE per `--scheduled-run` process, after all
/// per-profile work, so a fleet-wide missed run still reaches the operator.
///
/// The overdue evaluation is fleet-wide (all JRC LaunchAgents); the notify
/// webhook is resolved from the first non-excluded profile whose `notify:` is
/// usable. The `DayMarker(name: "overdue-notify")` once-per-day gate is SHARED
/// with the GUI path so the two never double-fire. Best-effort — never throws.
///
/// Accepted ordering gap (2.6.1 review): running AFTER the per-profile work
/// means a crash during that work suppresses this run's digest. Bounded, not
/// fixed: the backward-looking expected-fire check flags the miss on the next
/// evaluation (~grace period later), and the marker is stamped only after a
/// confirmed send, so a suppressed day retries on the next run.
@Sendable
func notifyOverdueSchedulesHeadless(
    profiles: [String], excluding excluded: Set<String> = []
) async {
    // Excluded profiles' own per-profile agents drop out of the fleet digest;
    // isMulti (fleet-wide) entries are never filtered — they cover every profile.
    let inputs = LaunchAgentService.healthInputs()
        .filter { $0.isMulti || !excluded.contains($0.profile) }
    let overdue = AutomationHealth.evaluate(inputs: inputs)
        .filter { $0.kind == .overdue }
    guard !overdue.isEmpty else { return }
    guard let resolved = firstUsableNotify(in: profiles) else {
        // No profile has a usable notify webhook = total silence on a real
        // overdue condition. Warn loudly rather than discover it only by
        // absence — mirrors notifyMetricAlerts' equivalent guard.
        let message = "[warn] \(overdue.count) overdue schedule(s) but no profile has a usable "
            + "notify webhook — overdue digest cannot be delivered"
        AppLogger.webhook.warning("\(message, privacy: .public)")
        fputs(message + "\n", stderr)
        return
    }
    let marker = DayMarker(name: "overdue-notify")
    let today = SummaryJSONParser.dateFormatter.string(from: Date())
    guard marker.lastStampedDay(in: resolved.workspace) != today else { return }

    // Reuse the GUI's fact builder so the two paths emit byte-identical cards
    // (and honor notify.detail minimal/full the same way).
    let facts = WorkspaceStore.overdueFacts(
        detail: resolved.notify.resolvedDetail, profile: resolved.profile, overdue: overdue
    )
    let sent = await WebhookNotifier.sendFailed(
        config: resolved.notify,
        title: "Scheduled run overdue — \(overdue.count) schedule" + (overdue.count == 1 ? "" : "s"),
        facts: facts
    )
    guard sent else { return }
    // Stamp only on a successful send so a transient webhook failure retries next run.
    marker.stamp(day: today, in: resolved.workspace)
    print("[info] overdue schedule digest posted headlessly (\(overdue.count) overdue)")
}

/// First profile in `profiles` (discovery order) whose `config.yaml` `notify:`
/// block is usable, with its notify config and workspace URL. nil when none
/// qualifies. Best-effort per profile — an unreadable/undecodable config skips.
private func firstUsableNotify(
    in profiles: [String]
) -> (profile: String, notify: NotifyConfig, workspace: URL)? {
    for profile in profiles {
        guard ProfileService.isValid(profile),
              let workspace = ProfileService.workspaceURL(for: profile) else { continue }
        let url = workspace.appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: url.path),
              let config = try? ConfigLoader.load(from: url),
              let notify = config.notify, notify.isUsable else { continue }
        return (profile, notify, workspace)
    }
    return nil
}

/// The installed jamf-cli version when it is present but below the supported
/// floor; nil when jamf-cli is absent (optional) or meets the floor. Uses the
/// nonisolated probe so it is callable from the headless `@Sendable` runner
/// without a MainActor hop.
@Sendable
private func jamfCLIVersionBelowFloor() -> String? {
    guard let binary = ExecutableLocator.locate("jamf-cli"),
          let installed = JamfCLIInstaller.installedVersion(at: binary),
          JamfCLIInstaller.isBelowMinimumSupported(installed) else { return nil }
    return installed
}

/// True unless `value` looks like another flag — guards `args[idx + 1]` reads
/// against silently consuming a missing value's own flag name (e.g.
/// `--profile --all-profiles` taking "--all-profiles" as the profile).
private func isFlagValue(_ value: String) -> Bool { !value.hasPrefix("--") }

@Sendable
private func scheduledRunSingle(
    profile: String,
    mode: Schedule.RunMode,
    tiers: Set<CollectionTier>?,
    verbose: Bool,
    label: String?
) async -> Int32 {
    guard ProfileService.isValid(profile) else {
        fputs("[error] Invalid profile '\(profile)'\n", stderr)
        return 1
    }
    guard let workspace = ProfileService.workspaceURL(for: profile) else {
        fputs("[error] No workspace for profile '\(profile)'\n", stderr)
        return 1
    }

    // Rotate run-history logs at the start of each scheduled invocation so
    // logs in <workspace>/automation/logs/ don't grow unbounded.
    // Best-effort: rotation failure must not abort the run.
    if let logsDir = try? WorkspacePaths.runHistoryDir(for: profile) {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: logsDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []
        for entry in entries where entry.pathExtension == "log" {
            do {
                try LaunchAgentLogRotator.rotateIfNeeded(logURL: entry)
            } catch {
                fputs(
                    "[warn] could not rotate \(entry.lastPathComponent): \(error.localizedDescription)\n",
                    stderr
                )
            }
        }
    }

    // Per-run record in <workspace>/automation/ — this is what Run History
    // and the Schedules "Last Run" column read. The launchd stdout/stderr
    // redirect to ~/Library/Logs/JamfReports/<label>/ is unchanged (raw
    // stream capture); the recorder is the structured per-run record.
    // Legacy plists without --label fall back to a profile+mode label so
    // their runs are recorded too.
    let runLabel = label ?? "\(LaunchAgentWriter.labelPrefix).\(profile).\(mode.rawValue)"
    let recorder = ScheduledRunRecorder(workspace: workspace, label: runLabel)
    if recorder == nil {
        fputs("[warn] could not open run record in automation/logs — run will not appear in Run History\n", stderr)
    }

    // `ReportEngine.collect` returns Void — CollectRouter's typealias and its
    // test spies depend on that — so the two facts that make a bare exit 0 a
    // lie arrive on the log stream instead: this Mac stood down for a peer, or
    // the day's summary never reached disk. Watching the stream is what lets
    // the completion line and the webhook below say which one happened.
    let honesty = CollectHonestyWatcher()
    let onLine: @Sendable (CLIBridge.LogLine) -> Void = { line in
        honesty.observe(line.text)
        recorder?.record(line.text)
        if verbose || line.level != .info {
            print(line.text)
        }
    }

    // Version-floor preflight (v2.2.0 Phase 3): abort loudly when an installed
    // jamf-cli is below the supported floor, before any collect/backup, so a
    // scheduled run never silently writes data from an unsupported binary.
    // jamf-cli-only generates from cache and never calls jamf-cli, so it is
    // exempt; an absent jamf-cli is also exempt (the collect path handles it).
    if mode != .jamfCLIOnly, let belowVersion = jamfCLIVersionBelowFloor() {
        let message = "[error] jamf-cli \(belowVersion) is below the supported floor "
            + "\(JamfCLIInstaller.minimumSupportedVersion) — aborting '\(profile)' to avoid "
            + "writing data from an unsupported binary. Run: brew upgrade jamf-cli"
        fputs(message + "\n", stderr)
        recorder?.record(message)
        recorder?.finish(exitCode: 1)
        return 1
    }

    // Load config once, before the backup branch (product-type routing needs
    // it), before collect (routing needs it) and before generate. Failure
    // degrades routing to Jamf Pro and still fails generate with the real error
    // (ConfigLoader.LoadError) so the recorded run shows a meaningful message.
    // nil config in routing logs loudly and uses Pro.
    let configURL = workspace.appendingPathComponent("config.yaml")
    let routingConfig: ReportConfig? = {
        guard let loaded = try? ConfigLoader.load(from: configURL) else {
            AppLogger.schedule.warning(
                "[routing] could not load config for \(profile, privacy: .public) — defaulting to Jamf Pro"
            )
            return nil
        }
        return loaded
    }()

    // Backup mode (v2.2.0): export configuration objects; no collect, no
    // generate. Retention prunes scheduled backups beyond the newest 10 and
    // sweeps abandoned .tmp-* staging dirs.
    if mode == .backup {
        // `pro backup` is a Jamf Pro-namespace command, so it can only ever
        // succeed for a Jamf Pro profile. Running it against a Jamf School
        // profile fails identically on every retry, which pins a permanent
        // "Backup failed" health row the operator has no way to clear (#213).
        // A schedule that has nothing to do for a profile is not a failed
        // schedule — log why and return success.
        guard ProfileProductType.detect(from: routingConfig).type == .jamfPro else {
            let message = "[skip] scheduled backup skipped for '\(profile)': `pro backup` is a "
                + "Jamf Pro command and this profile is configured for Jamf School "
                + "(school_cli.enabled in config.yaml). Nothing to back up — not a failure. "
                + "Exclude this profile from the backup schedule to stop scheduling it."
            print(message)
            recorder?.record(message)
            recorder?.finish(exitCode: 0)
            return 0
        }
        do {
            let bridge = CLIBridge()
            let exit = try await bridge.backup(
                profile: profile,
                label: "scheduled-\(BackupMaintenance.dateStamp())",
                onLine: onLine
            )
            // Exit 7 keeps its partial export on disk, so retention has to see
            // it — otherwise partial backups accumulate unpruned forever. The
            // run itself still reports non-success: an incomplete backup is not
            // a restore point, and the row should stay red until it's fixed.
            if CLIBridge.backupOutputIsPrunable(exit: exit) {
                BackupMaintenance.performPostSuccessHousekeeping(profile: profile, onLine: onLine)
            }
            // Explain the exit code (cause + remediation) instead of a bare
            // integer — same translation the GUI's Backups screen already shows
            // for this identical failure.
            let failureDetail: String? = exit == 0 ? nil : CLIBridge.explainExit(
                exit, operation: "Scheduled backup for '\(profile)'"
            )
            let message = failureDetail.map { "[error] " + $0 }
                ?? "[ok] scheduled backup complete for '\(profile)'"
            if failureDetail == nil { print(message) } else { fputs(message + "\n", stderr) }
            recorder?.record(message)
            recorder?.finish(exitCode: exit)
            // Post the failure digest — backup returns before the outer catch, so
            // without this an operator watching the notify webhook gets silence
            // for every unattended backup failure and reads it as success.
            // Best-effort, after the recorder is finished so webhook latency
            // never blocks the exit path.
            if let failureDetail {
                await ScheduledRunSignals.notifyScheduledRunFailure(
                    config: routingConfig, profile: profile, mode: mode,
                    errorDescription: failureDetail, recorder: nil
                )
            }
            return exit
        } catch {
            let errorDesc = error.localizedDescription
            let message = "[error] scheduled backup failed for '\(profile)': \(errorDesc)"
            fputs(message + "\n", stderr)
            recorder?.record(message)
            recorder?.finish(exitCode: 1)
            await ScheduledRunSignals.notifyScheduledRunFailure(
                config: routingConfig, profile: profile, mode: mode,
                errorDescription: errorDesc, recorder: nil
            )
            return 1
        }
    }

    // PR-21: csv-assisted hard-fails when csv-inbox/ is empty. Resolve up
    // front so we don't run an expensive collect just to fail at generate.
    let resolvedCSV: URL?
    if mode == .csvAssisted {
        guard let csv = CLIBridge.newestCSV(in: profile) else {
            let message = "[error] csv-assisted requires a CSV in csv-inbox/ — none found for '\(profile)'"
            fputs(message + "\n", stderr)
            recorder?.record(message)
            recorder?.finish(exitCode: 1)
            return 1
        }
        resolvedCSV = csv
    } else if mode == .jamfCLIFull {
        resolvedCSV = nil  // jamf-cli-full is the no-CSV path
    } else {
        resolvedCSV = nil
    }

    do {
        // jamf-cli-only generates from cache only — no collect, no fresh API calls.
        // The other three modes all need fresh snapshots.
        if mode != .jamfCLIOnly {
            // PR-23 T-20: the schedule's plist pins the tier set via
            // --tiers. When present, it wins — it's the operator's choice
            // (or the form's mode-derived default). When absent (pre-PR-23
            // plists, or any caller that doesn't pass tiers), fall back to
            // the mode default: snapshot-only → Refresh only (PR-22 T-10),
            // the generate modes → all tiers.
            let resolvedTiers = tiers ?? mode.defaultTiers
            // Route to the correct collect function(s) based on profile product type.
            // Scheduled collects never bypass the once-per-day guard (force: false).
            try await CollectRouter.run(
                profile: profile,
                tiers: resolvedTiers,
                config: routingConfig,
                onLine: onLine
            )
            // Tighten permissions on collected snapshots immediately after
            // collect, before generate, so a crash or early exit still
            // leaves collected files at 0600. Mirrors the GUI's tightenOnSuccess.
            await WorkspacePermissionHardener.tighten(profile: profile)
        }
        // snapshot-only stops after collect; summary.json is already written.
        // Only Jamf Pro collect (via ReportEngine.collect) writes summary.json;
        // School collect does not — avoid a false "Trends updated" claim for School.
        if mode == .snapshotOnly {
            let detected = ProfileProductType.detect(from: routingConfig)
            // Trends only moved if a Jamf Pro collect ran AND its summary
            // reached disk. Claiming it otherwise is the specific lie this
            // release is closing: the operator reads "Trends updated" as proof
            // the fleet was polled today.
            let trendsSuffix = detected.type == .jamfPro && honesty.producedFreshSnapshot
                ? " — Trends updated" : ""
            let message = honesty.stoodDown
                ? "[ok] scheduled snapshot for '\(profile)' stood down — another machine "
                    + "in this shared workspace collected recently"
                : "[ok] scheduled snapshot complete for '\(profile)'\(trendsSuffix)"
            print(message)
            recorder?.record(message)
            // A snapshot-only run's entire product is the day's summary — it
            // renders no workbook — so a success card from a run that wrote no
            // summary names an artifact that does not exist. Both markers
            // therefore suppress it: a stand-down (nothing collected) and a
            // summary that never reached disk. Exit 0 is still right for both —
            // standing down is the coordination working, and the `[partial]`
            // line already downgrades the run in Run History. The failure-card
            // path is unchanged: a run that threw never gets here.
            if honesty.producedFreshSnapshot {
                await ScheduledRunSignals.notifyScheduledRun(
                    config: routingConfig, profile: profile, mode: mode,
                    artifact: nil, recorder: recorder
                )
                await ScheduledRunSignals.notifyMetricAlerts(
                    config: routingConfig, profile: profile, workspace: workspace,
                    recorder: recorder
                )
            }
            ScheduledRunSignals.recordConfigHealth(profile: profile, recorder: recorder)
            recorder?.finish(exitCode: 0)
            return 0
        }

        let config = try routingConfig ?? ConfigLoader.load(from: configURL)
        let dataDir = try WorkspacePaths.dataDir(for: profile)

        // Shared workspaces: don't render the same report twice. Placed here
        // rather than inside ReportEngine.generate, which derives its profile
        // from config and has many callers — the duplicates come from two
        // LaunchAgents firing, and this is where both of those land.
        //
        // No freshness check: "has someone collected recently" governs
        // collecting, not rendering. A scheduled generate only defers to a peer
        // actively writing right now.
        var holdsGenerateClaim = false
        switch ReportEngine.coordinationGate(
            profile: profile, force: false, operation: "generate", checkFreshness: false
        ) {
        case .standDown(let reason):
            // Same `[partial]` line the collect-side twin emits: two runs that
            // both did nothing must read alike in Run History, or a deferred
            // generate looks like a report that rendered.
            let line = ReportEngine.standDownLine(reason: reason)
            print(line)
            recorder?.record(line)
            recorder?.finish(exitCode: 0)
            return 0
        case .proceed(let state, let notes):
            holdsGenerateClaim = state.holdsClaim
            for note in notes {
                print(note)
                recorder?.record(note)
            }
        }
        defer { if holdsGenerateClaim { SharedWorkspace.release(profile: profile) } }

        let engine = ReportEngine(config: config, dataDir: dataDir)
        let outputURL = engine.resolveOutputURL(stem: "report", profile: profile)
        // onLine only carries CLIBridge.LogLine progress during generate; per-sheet
        // [fail] lines are raw `print` calls in SheetRegistry and bypass both onLine
        // and the recorder — they reach the console/launchd log only, not Run History.
        let failures = try await engine.generate(
            csvURL: resolvedCSV,
            outputURL: outputURL,
            onLine: onLine
        )
        if !failures.isEmpty {
            let partialMsg = partialRunMarker(sheetFailures: failures.count)
            recorder?.record(partialMsg)
        }
        let message = "[ok] scheduled run complete for '\(profile)': \(outputURL.lastPathComponent)"
        print(message)
        recorder?.record(message)
        // Tighten permissions on generated report and any newly written files.
        await WorkspacePermissionHardener.tighten(profile: profile)
        await ScheduledRunSignals.notifyScheduledRun(
            config: config, profile: profile, mode: mode,
            artifact: outputURL.lastPathComponent,
            sheetFailures: failures.count,
            recorder: recorder
        )
        // jamf-cli-only generates from cache without a fresh collect, so its
        // summary isn't "just produced" — skip alerting for it. A collect that
        // stood down for a peer is the same situation arrived at differently:
        // the report is real (it rendered from cache), but no summary was
        // written this run, so there is nothing new to alert on.
        if mode != .jamfCLIOnly, !honesty.stoodDown {
            await ScheduledRunSignals.notifyMetricAlerts(
                config: config, profile: profile, workspace: workspace, recorder: recorder
            )
        }
        ScheduledRunSignals.recordConfigHealth(profile: profile, recorder: recorder)
        recorder?.finish(exitCode: 0, sheetFailures: failures.count, artifacts: [outputURL])
        return 0
    } catch {
        let errorDesc = error.localizedDescription
        let message = "[error] '\(profile)': \(errorDesc)"
        fputs(message + "\n", stderr)
        recorder?.record(message)
        recorder?.finish(exitCode: 1)
        // Post failure digest — best-effort, after recorder is finished so the
        // webhook send latency never blocks the exit path.
        await ScheduledRunSignals.notifyScheduledRunFailure(
            config: routingConfig, profile: profile, mode: mode,
            errorDescription: errorDesc, recorder: nil
        )
        return 1
    }
}

@Sendable
private func scheduledRun(profile: String) async -> Int32 {
    let args = CommandLine.arguments
    let verbose = args.contains("--verbose")
    let allProfiles = args.contains("--all-profiles")
    // Legacy plists (pre-PR-20) omit --mode; fall back to jamf-cli-only so the
    // existing behavior (collect + generate, no CSV) is preserved verbatim.
    let mode: Schedule.RunMode = {
        guard let idx = args.firstIndex(of: "--mode"), idx + 1 < args.count,
              isFlagValue(args[idx + 1]) else {
            return .jamfCLIOnly
        }
        return Schedule.RunMode(rawValue: args[idx + 1]) ?? .jamfCLIOnly
    }()

    // PR-23 T-20: --tiers <csv> pins the collect tier set. Absent (pre-PR-23
    // plists) → nil, and scheduledRunSingle falls back to the mode default.
    // Unknown tokens are dropped; an all-unknown CSV resolves to nil.
    let tiers: Set<CollectionTier>? = {
        guard let idx = args.firstIndex(of: "--tiers"), idx + 1 < args.count,
              isFlagValue(args[idx + 1]) else {
            return nil
        }
        var parsed: Set<CollectionTier> = []
        for token in args[idx + 1].split(separator: ",") {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if let tier = CollectionTier(rawValue: trimmed) { parsed.insert(tier) }
        }
        return parsed.isEmpty ? nil : parsed
    }()

    // --label <agent-label> names the per-run record in automation/ so Run
    // History and the Schedules screen attribute the run to its schedule.
    // Absent on plists written before the recorder existed; the run is then
    // recorded under a profile+mode fallback label.
    let label: String? = {
        guard let idx = args.firstIndex(of: "--label"), idx + 1 < args.count,
              isFlagValue(args[idx + 1]),
              LaunchAgentWriter.isValidLabel(args[idx + 1]) else {
            return nil
        }
        return args[idx + 1]
    }()

    // --exclude-profiles <csv> drops profiles from the run-time-discovered set
    // (run-time exclusion — never a positive --multi-profiles list, so a
    // managed all-profiles agent still picks up profiles added later).
    let excludeArg: String? = {
        guard allProfiles,
              let idx = args.firstIndex(of: "--exclude-profiles"), idx + 1 < args.count,
              isFlagValue(args[idx + 1]) else {
            return nil
        }
        return args[idx + 1]
    }()
    let schedule = Schedule(
        name: label ?? mode.rawValue, profile: profile, schedule: "manual", cadence: "custom",
        mode: mode, next: "—", last: "—", lastStatus: .ok, artifacts: [], enabled: true,
        launchAgentLabel: label,
        multiTarget: allProfiles ? MultiTarget(scope: .all, sequential: true) : nil,
        tiers: tiers,
        excludedProfiles: allProfiles ? Array(ProfileService.parseExclusions(excludeArg)) : nil
    )
    let code = await runSchedule(schedule, verbose: verbose)
    // External-scheduler path only: the tick posts its own digest once per wake.
    await notifyOverdueSchedulesHeadless(
        profiles: allProfiles ? ProfileService.discoverLocal().map(\.name) : [profile],
        excluding: Set(schedule.excludedProfiles ?? []))
    return code
}

/// One schedule, start to finish: the body every scheduler shares (`--tick`,
/// `--scheduled-run` from an external cron, Run now). Records under the
/// schedule's label; a multi schedule fans out over discovered profiles minus
/// its exclusions and emits the consolidated fleet report for report modes.
@Sendable
func runSchedule(_ schedule: Schedule, verbose: Bool) async -> Int32 {
    let label = schedule.launchAgentLabel
    guard schedule.isMulti else {
        return await scheduledRunSingle(
            profile: schedule.profile, mode: schedule.mode, tiers: schedule.tiers,
            verbose: verbose, label: label)
    }
    let excluded = Set(schedule.excludedProfiles ?? [])
    let profiles = ProfileService.applyingExclusions(
        ProfileService.discoverLocal(), excluding: excluded)
    guard !profiles.isEmpty else {
        fputs("[error] \(label ?? "all-profiles"): no local profiles found\n", stderr)
        return 1
    }
    if !excluded.isEmpty {
        fputs("[info] excluding: \(excluded.sorted().joined(separator: ", "))\n", stderr)
    }
    var anyFailed = false
    for p in profiles {
        let code = await scheduledRunSingle(
            profile: p.name, mode: schedule.mode, tiers: schedule.tiers,
            verbose: verbose, label: label)
        if code != 0 { anyFailed = true }
    }
    if [.jamfCLIOnly, .jamfCLIFull, .csvAssisted].contains(schedule.mode) {
        emitConsolidatedReports()
    }
    return anyFailed ? 1 : 0
}

// MARK: - check subcommand

@Sendable
func runCheck(profile: String) -> Int32 {
    guard ProfileService.isValid(profile) else {
        fputs("[error] Invalid profile '\(profile)'\n", stderr)
        return 1
    }
    guard let workspace = ProfileService.workspaceURL(for: profile) else {
        fputs("[error] No workspace for profile '\(profile)'\n", stderr)
        return 1
    }
    let configURL = workspace.appendingPathComponent("config.yaml")
    guard FileManager.default.fileExists(atPath: configURL.path) else {
        fputs("[error] config.yaml not found at \(configURL.path)\n", stderr)
        return 1
    }
    do {
        let config = try ConfigLoader.load(from: configURL)
        let cliProfile = config.jamfCli?.resolvedProfile ?? profile
        print("[ok] config.yaml decoded successfully")
        print("[ok] jamf_cli.profile: \(cliProfile.isEmpty ? "(not set)" : cliProfile)")
        let dataDir = (try? WorkspacePaths.dataDir(for: profile)) ?? workspace
            .appendingPathComponent("jamf-cli-data")
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dataDir.path, isDirectory: &isDir) {
            print("[warn] data_dir does not exist yet (no collect run): \(dataDir.path)")
        } else if !isDir.boolValue {
            fputs("[warn] data_dir path exists but is not a directory: \(dataDir.path)\n", stderr)
        } else {
            do {
                let snapshotCount = try FileManager.default.contentsOfDirectory(atPath: dataDir.path).count
                print("[ok] cached snapshots in data_dir: \(snapshotCount)")
            } catch {
                fputs("[warn] could not read data_dir: \(error.localizedDescription)\n", stderr)
            }
        }

        // The checks above only prove the file parses. Everything an operator
        // actually gets wrong — column mappings that no longer match their CSV,
        // baselines pointing at absent EAs, malformed alert rules, a workspace
        // on a shared folder with no coordination — lives in the Config Doctor,
        // which the GUI has surfaced since 2.3.0 while `check` did not. Same
        // report, same rules, one implementation.
        return printDoctorReport(ConfigDoctorService.run(profile: profile))
    } catch {
        fputs("[error] \(error.localizedDescription)\n", stderr)
        return 1
    }
}

/// Render a `DoctorReport` as `check` output and turn it into an exit code.
///
/// Passes are summarised as a count rather than listed: a healthy config emits
/// dozens of them and burying three warnings in that list is how a check gets
/// ignored. Only `.fail` sets a non-zero exit — a warning is something to look
/// at, not a reason to fail a scripted run.
func printDoctorReport(_ report: DoctorReport) -> Int32 {
    let actionable = report.rows.filter { $0.severity != .pass }

    print("[ok] config checks passed: \(report.passCount)")
    for row in actionable.sorted(by: { severityRank($0.severity) < severityRank($1.severity) }) {
        let tag: String
        switch row.severity {
        case .fail: tag = "error"
        case .warn: tag = "warn"
        case .suggest: tag = "info"
        case .pass: continue
        }
        // Every row goes to stdout, failures included. Splitting a report
        // across two streams looked tidier but reordered it on a terminal:
        // stderr is unbuffered and stdout is not, so findings arrived before
        // the header and each "fix:" line detached from the finding it
        // belonged to. The exit code is the machine-readable signal; a
        // readable report is worth more than per-row stream convention.
        print("[\(tag)] \(row.title): \(row.detail)")
        if let hint = row.hint {
            print("        fix: \(hint)")
        }
    }

    if report.failCount > 0 {
        fflush(stdout)
        fputs("[error] \(report.failCount) check(s) must be fixed before reports are reliable\n",
              stderr)
        return 1
    }
    if report.warnCount > 0 {
        print("[warn] \(report.warnCount) check(s) need attention")
    }
    return 0
}

private func severityRank(_ severity: DoctorSeverity) -> Int {
    switch severity {
    case .fail: return 0
    case .warn: return 1
    case .suggest: return 2
    case .pass: return 3
    }
}

// MARK: - school-check subcommand

@Sendable
func runSchoolCheck(profile: String) -> Int32 {
    guard ProfileService.isValid(profile) else {
        fputs("[error] Invalid profile '\(profile)'\n", stderr)
        return 1
    }
    guard let workspace = ProfileService.workspaceURL(for: profile) else {
        fputs("[error] No workspace for profile '\(profile)'\n", stderr)
        return 1
    }
    let configURL = workspace.appendingPathComponent("config.yaml")
    guard FileManager.default.fileExists(atPath: configURL.path) else {
        fputs("[error] config.yaml not found at \(configURL.path)\n", stderr)
        return 1
    }
    do {
        _ = try ConfigLoader.load(from: configURL)
        print("[ok] config.yaml decoded successfully")
        let schoolSnapshotKinds = [
            "school-overview", "school-devices", "school-device-groups",
            "school-users", "school-classes", "school-apps",
            "school-profiles", "school-locations",
        ]
        if let dataDir = try? WorkspacePaths.dataDir(for: profile) {
            let fm = FileManager.default
            for kind in schoolSnapshotKinds {
                let kindDir = dataDir.appendingPathComponent(kind)
                let exists = fm.fileExists(atPath: kindDir.path)
                print("[\(exists ? "ok" : "miss")] snapshot \(kind): \(exists ? "present" : "missing")")
            }
        }
        return 0
    } catch {
        fputs("[error] \(error.localizedDescription)\n", stderr)
        return 1
    }
}

// MARK: - school-scaffold subcommand

func runSchoolScaffold(csvPath: String, outPath: String) -> Int32 {
    let csvURL = URL(fileURLWithPath: csvPath)
    let outURL = URL(fileURLWithPath: outPath)
    if WorkspacePaths.isSensitiveAbsolutePath(outURL) {
        fputs("[error] refusing to write into a sensitive path: \(outPath)\n", stderr)
        return 1
    }
    guard FileManager.default.fileExists(atPath: csvURL.path) else {
        fputs("[error] CSV not found: \(csvPath)\n", stderr)
        return 1
    }
    guard let data = try? Data(contentsOf: csvURL),
          let text = String(data: data, encoding: .utf8) else {
        fputs("[error] Could not read CSV: \(csvPath)\n", stderr)
        return 1
    }
    // Parse header row (comma or semicolon delimited, matching Python _school_csv_load).
    let firstLine = text.components(separatedBy: "\n").first ?? ""
    let delimiter: Character = firstLine.contains(";") ? ";" : ","
    let headers = firstLine.components(separatedBy: String(delimiter))
        .map { $0.trimmingCharacters(in: .init(charactersIn: "\r\"\u{feff}")) }

    let mappings = schoolScaffoldMappings(from: headers)

    var lines = ["# config.yaml — Jamf School columns (appended by school-scaffold)", "school_columns:"]
    let orderedKeys = [
        "device_name", "serial_number", "operating_system", "last_checkin",
        "model", "managed", "supervised", "username", "email",
        "device_family", "asset_tag", "location",
    ]
    for key in orderedKeys {
        let value = mappings[key] ?? ""
        lines.append("  \(key): \"\(ScaffoldService.yamlEscape(value))\"")
    }
    lines.append("")

    do {
        let fm = FileManager.default
        if fm.fileExists(atPath: outURL.path),
           let existing = try? String(contentsOf: outURL, encoding: .utf8) {
            let appended = existing.hasSuffix("\n") ? existing + lines.joined(separator: "\n")
                : existing + "\n" + lines.joined(separator: "\n")
            try appended.write(to: outURL, atomically: true, encoding: .utf8)
        } else {
            try fm.createDirectory(at: outURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try lines.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
        }
        print("[ok] school_columns written to \(outURL.lastPathComponent)")
        return 0
    } catch {
        fputs("[error] \(error.localizedDescription)\n", stderr)
        return 1
    }
}

/// Fuzzy-match CSV headers to Jamf School logical field names.
/// Mirrors Python's `SCHOOL_COLUMN_HINTS` / `SCHOOL_COLUMN_EXCLUDES` logic.
private func schoolScaffoldMappings(from headers: [String]) -> [String: String] {
    // Each entry: logical key → hint substrings (case-insensitive contains).
    let hints: [String: [String]] = [
        "device_name":      ["device name", "name"],
        "serial_number":    ["serial"],
        "operating_system": ["operating system", "os version", "ios version", "ipados"],
        "last_checkin":     ["last check", "last inventory", "last contact", "last seen"],
        "model":            ["model"],
        "managed":          ["managed"],
        "supervised":       ["supervised"],
        "username":         ["username", "user name", "assigned user"],
        "email":            ["email"],
        "device_family":    ["device family", "device type", "type"],
        "asset_tag":        ["asset tag", "asset"],
        "location":         ["location"],
    ]
    // Substrings that must NOT match even if the hint fires.
    let excludes: [String: [String]] = [
        "device_name":  ["model", "type", "family"],
        "model":        ["model name"],
        "last_checkin": ["enrollment"],
    ]
    let lower = headers.map { $0.lowercased() }
    var result: [String: String] = [:]
    for (key, hintList) in hints {
        for hint in hintList {
            guard let idx = lower.firstIndex(where: { $0.contains(hint) }) else { continue }
            let candidate = lower[idx]
            let blocked = (excludes[key] ?? []).contains { candidate.contains($0) }
            if !blocked {
                result[key] = headers[idx]
                break
            }
        }
    }
    return result
}

// MARK: - Included CLI dispatch

/// Run the included `jamf-reports` CLI for `arguments` (subcommand + its args,
/// binary name already dropped).
///
/// Isolated in an `@available`-annotated function on purpose: ArgumentParser's
/// async `main`/`run` entry points are gated `@available(macOS 10.15, *)`, and in
/// unannotated top-level executable code overload resolution falls back to the
/// synchronous overloads — which refuse to execute an async root command (they
/// print help and exit). The explicit availability context makes the async
/// overloads win, so `AsyncParsableCommand.run()` is actually awaited.
@available(macOS 14, *)
func runIncludedCLI(_ arguments: [String]) async {
    await JamfReportsCLI.main(arguments)
}

// MARK: - Entry point

// Install uncaught-exception handler before any UI or CLI work. Crash logs land at
// ~/Library/Logs/JamfReports/crash_<timestamp>.log.
CrashReporter.install()

let cliArgs = CommandLine.arguments
// Anchored to position (not a whole-array `contains`) so an option VALUE that
// happens to equal "--scheduled-run" can't divert the process — mirrors
// LaunchAgentWriter's plist parser (`args[1] == "--scheduled-run"`) and the
// isKnownSubcommand check below (`cliArgs[1]`).
if cliArgs.count > 1, cliArgs[1] == "--tick" {
    let code = Task.detached { await runTick(arguments: cliArgs) }
    exit(await code.value)
} else if cliArgs.count > 1, cliArgs[1] == "--scheduled-run",
   let profileIdx = cliArgs.firstIndex(of: "--profile"),
   profileIdx + 1 < cliArgs.count,
   isFlagValue(cliArgs[profileIdx + 1]) {
    let profile = cliArgs[profileIdx + 1]
    let code = Task.detached { await scheduledRun(profile: profile) }
    let exitCode = await code.value
    exit(exitCode)
} else if cliArgs.count > 1, JamfReportsCLI.isKnownSubcommand(cliArgs[1]) {
    // Included CLI: `jamf-reports <subcommand> …` (Sources/JamfReports/CLI/).
    await runIncludedCLI(Array(cliArgs.dropFirst()))
} else {
    // No recognized subcommand (incl. double-click launch) → the GUI.
    JamfReportsApp.main()
}
