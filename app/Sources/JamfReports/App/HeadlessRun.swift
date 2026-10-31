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
    let policy = TickEnvironment.storedPolicy()
    guard !policy.reportGroups.isEmpty else { return }
    let lookback: Int = {
        switch policy.reportsCadence {
        case .daily:   return 1
        case .monthly: return 30
        case .weekly, .off: return 7
        }
    }()
    let stamp = ExportNaming.timestamp()
    // One refusal for the whole run, not one per group.
    let outputDir: URL
    do {
        outputDir = try FleetReportEmitter.consolidatedDir()
    } catch {
        let message = "[warn] consolidated reports not written: _fleet-reports is not used: "
            + WorkspacePaths.refusal(of: error) + "."
        fputs(message + "\n", stderr)
        record(message)
        return
    }
    for group in policy.reportGroups {
        do {
            if let url = try FleetReportEmitter.emit(
                group: group, lookbackDays: lookback, timestamp: stamp, outputDir: outputDir
            ) {
                print("[ok] consolidated fleet report: \(url.lastPathComponent)")
            }
            if let xlsxURL = try FleetWorkbookEmitter.emit(
                group: group, lookbackDays: lookback, timestamp: stamp, outputDir: outputDir
            ) {
                print("[ok] consolidated fleet workbook: \(xlsxURL.lastPathComponent)")
            }
        } catch {
            // LogRedactor masks credentials, not paths or hosts; redact once for all three sinks.
            let message = LogRedactor.redact(
                "[warn] consolidated report for '\(group.name)' failed: "
                    + error.localizedDescription)
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
    do {
        try FleetReportEmitter.appendLog(message, in: try FleetReportEmitter.consolidatedDir())
    } catch {
        AppLogger.schedule.warning(
            "appendFleetLog: could not write fleet-reports.log: \(error.localizedDescription, privacy: .private)"
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
/// The overdue evaluation spans every profile, but each profile's schedules go
/// only to that profile's own `notify:` webhook; a fleet-wide (`isMulti`)
/// schedule goes to every usable webhook (`OverdueDigestRouting`). A profile
/// with no usable webhook is warned about, never cross-posted. Each send is
/// gated by that workspace's `DayMarker(name: "overdue-notify")`, SHARED with
/// the GUI path so the two never double-fire. Best-effort — never throws.
///
/// Accepted ordering gap (2.6.1 review): running AFTER the per-profile work
/// means a crash during that work suppresses this run's digest. Bounded, not
/// fixed: the backward-looking expected-fire check flags the miss on the next
/// evaluation (~grace period later), and the marker is stamped only after a
/// confirmed send, so a suppressed day retries on the next run.
@Sendable
func notifyOverdueSchedulesHeadless(
    profiles: [String], excluding excluded: Set<String> = [],
    policy: AutomationPolicy = TickEnvironment.storedPolicy()
) async {
    // Excluded profiles' own per-profile agents drop out of the fleet digest;
    // isMulti (fleet-wide) entries are never filtered — they cover every profile.
    let schedules = WorkspaceStore.loadSchedules(
        policy: policy,
        baseProfile: ManagedAutomation.managedBaseProfile(names: profiles, policy: policy))
    let inputs = LaunchAgentService.healthInputs(schedules: schedules, statusProfile: nil)
        .filter { $0.isMulti || !excluded.contains($0.profile) }
    let overdue = AutomationHealth.evaluate(inputs: inputs)
        .filter { $0.kind == .overdue }
    guard !overdue.isEmpty else { return }

    let marker = DayMarker(name: "overdue-notify")
    let today = SummaryJSONParser.dateFormatter.string(from: Date())
    let runProfiles = profiles.filter { !excluded.contains($0) }
    let targets = notifyTargets(in: runProfiles) {
        marker.isStamped(today, in: $0)
    }
    let routing = OverdueDigestRouting.route(
        overdue: overdue, targets: targets, runProfiles: runProfiles)

    if !routing.undeliverable.isEmpty {
        // A real overdue condition with no webhook to carry it = silence.
        // Warn loudly rather than discover it only by absence — mirrors
        // notifyMetricAlerts' equivalent guard.
        let owners = Set(routing.undeliverable.map { $0.isMulti ? "all profiles" : $0.profile })
            .sorted().joined(separator: ", ")
        let message = "[warn] \(routing.undeliverable.count) overdue schedule(s) for \(owners) "
            + "but no usable notify webhook — overdue digest cannot be delivered"
        AppLogger.webhook.warning("\(message, privacy: .private)")
        fputs(message + "\n", stderr)
    }

    for batch in routing.batches {
        await postOverdueDigest(batch, marker: marker, today: today)
    }
}

/// One overdue card for `batch`. Its outcome opens or clears `webhookRejected` for every
/// profile on the card, each in its own attention record (the app record, as for a heartbeat).
@discardableResult
func postOverdueDigest(
    _ batch: OverdueDigestRouting.Batch, marker: DayMarker, today: String
) async -> DayMarker.SendOutcome {
    // Reuse the GUI's fact builder so the two paths emit byte-identical cards
    // (and honor notify.detail minimal/full the same way).
    let names = batch.profiles.joined(separator: ", ")
    let facts = WorkspaceStore.overdueFacts(
        detail: batch.notify.resolvedDetail, profile: names, overdue: batch.issues)
    let count = batch.issues.count
    // One card can cover several workspaces; it names their organisation only when they agree.
    let organizations = Set(batch.profiles.compactMap(WebhookNotifier.organization(profile:)))
    let organization = organizations.count == 1 ? organizations.first : nil
    let failure = WebhookNotifier.DeliveryFailure()
    let outcome = await marker.sendOnce(
        day: today, in: batch.targets.map(\.workspace),
        onLine: { fputs($0 + "\n", stderr) }
    ) {
        await WebhookNotifier.sendFailed(
            config: batch.notify,
            title: "Scheduled run overdue — \(count) schedule" + (count == 1 ? "" : "s"),
            facts: facts, organization: organization, failure: failure
        )
    }
    for profile in batch.profiles {
        await AttentionLog.recording(profile: profile) {
            ScheduledRunSignals.noteWebhook(outcome, failure: failure)
        }
    }
    switch outcome {
    case .sent:
        print("[info] overdue schedule digest posted headlessly for \(names) (\(count) overdue)")
    case .failed:
        // Stamped only after a confirmed send, so a failed one retries next run.
        let message = "[warn] overdue digest notification failed for \(names): "
            + (failure.reason ?? "unknown")
        fputs(message + "\n", stderr)
        AppLogger.webhook.error("\(message, privacy: .private)")
    case .skipped: break
    }
    return outcome
}

/// A target for each profile in `profiles` whose `config.yaml` `notify:` block is
/// usable, in discovery order. Best-effort per profile — an unreadable config is left out; one
/// that does not decode still contributes its `notify:` block. A case variant is left out: its
/// path is another spelling's folder, whose webhook and day stamps are not its own.
func notifyTargets(
    in profiles: [String], sentToday: (URL) -> Bool
) -> [OverdueDigestRouting.Target] {
    profiles.compactMap { profile in
        guard ProfileService.isValid(profile),
              ProfileService.caseVariantWorkspace(of: profile) == nil,
              let workspace = ProfileService.workspaceURL(for: profile) else { return nil }
        let url = workspace.appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: url.path),
              let notify = SharedConfigPin.effectiveNotify(
                  (try? ConfigLoader.load(from: url))?.notify ?? NotifyConfigLoader.scoped(at: url),
                  profile: profile),
              notify.isUsable else { return nil }
        return OverdueDigestRouting.Target(
            profile: profile, notify: notify, workspace: workspace,
            sentToday: sentToday(workspace))
    }
}

/// True unless `value` looks like another flag — guards `args[idx + 1]` reads
/// against silently consuming a missing value's own flag name (e.g.
/// `--profile --all-profiles` taking "--all-profiles" as the profile).
private func isFlagValue(_ value: String) -> Bool { !value.hasPrefix("--") }

/// A workspace in `missing` (its jamf-cli profile does not exist) is skipped, not run: every
/// command would fail. One `[warn]` line, and a Needs attention item in that workspace that a
/// run of it clears once the profile exists.
private func skippedForMissingProfile(_ profile: String, missing: Set<String>) async -> Bool {
    guard missing.contains(profile) else { return false }
    let line = "[warn] skipping \(profile): jamf-cli has no profile of that name. Finish its "
        + "setup, exclude it in Automation, or remove its workspace folder."
    fputs(line + "\n", stderr)
    AppLogger.schedule.warning("\(line, privacy: .private)")
    await AttentionLog.recording(profile: profile) {
        AttentionLog.raise(.jamfCLIProfileMissing,
            "jamf-cli has no profile for this workspace, so scheduled runs skip it")
    }
    return true
}

@Sendable
private func scheduledRunSingle(
    profile: String,
    mode: Schedule.RunMode,
    tiers: Set<CollectionTier>?,
    verbose: Bool,
    label: String?,
    honesty: CollectHonestyWatcher,
    retiredCSVAssisted: Bool
) async -> Int32 {
    // Its attention items go into the run's status file once the recorder opens it, after
    // the failure card; a run refused before that writes none.
    await AttentionLog.recording(profile: profile, usesAppRecord: false) {
        await SharedConfigPin.announcingOnce {
            await scheduledRunSingleBody(
                profile: profile, mode: mode, tiers: tiers, verbose: verbose,
                label: label, honesty: honesty, retiredCSVAssisted: retiredCSVAssisted)
        }
    }
}

@Sendable
private func scheduledRunSingleBody(
    profile: String,
    mode: Schedule.RunMode,
    tiers: Set<CollectionTier>?,
    verbose: Bool,
    label: String?,
    honesty: CollectHonestyWatcher,
    retiredCSVAssisted: Bool
) async -> Int32 {
    // The run's day for its summary and its metric alerts, however long the collect takes.
    let runStart = Date()
    guard let workspaceID = WorkspaceID(profile) else {
        fputs("[error] Invalid profile '\(ConfigSchema.displayText(profile))'\n", stderr)
        return 1
    }
    // A case variant's path is another spelling's folder on a case-insensitive volume: its
    // config.yaml (and webhook) is not read and nothing is written there. Only a folder named
    // exactly as the profile, its own on a case-sensitive volume, is.
    let caseVariant = ProfileService.caseVariantRefusal(of: profile)
    let ownsFolder = caseVariant == nil || ProfileService
        .workspaceFolderNames(matching: ProfileName.folderKey(profile)).contains(profile)
    let workspace = WorkspacePaths.workspaceURL(for: workspaceID)
    // `runSchedule` skips a workspace with no jamf-cli profile before this, so it has one now.
    if mode != .jamfCLIOnly { AttentionLog.clear(.jamfCLIProfileMissing) }

    // Loaded once for the product refusal, the version preflight, routing and generate. A
    // config.yaml that exists but does not decode is kept as an error, not read as "no config":
    // the product (School, Pro) cannot be told from it, and reading it as Jamf Pro refused a
    // School profile with exit 0 on every run.
    let configURL = workspace.appendingPathComponent("config.yaml")
    var configError: Error?
    let routingConfig: ReportConfig?
    do {
        routingConfig = ownsFolder && FileManager.default.fileExists(atPath: configURL.path)
            ? try ConfigLoader.load(from: configURL) : nil
    } catch {
        routingConfig = nil
        configError = error
    }
    // A config the full decode rejects still carries the webhook the failure card goes to.
    let routingNotify = configError == nil ? nil : NotifyConfigLoader.scoped(at: configURL)
    if routingConfig == nil {
        AppLogger.schedule.warning(
            "[routing] no usable config for \(profile, privacy: .private) — treating as Jamf Pro")
    }

    let labelProfile = workspaceID.labelComponent
    let runLabel = label ?? "\(LaunchAgentWriter.labelPrefix).\(labelProfile).\(mode.rawValue)"
    // One failure card a day per schedule and profile for the same failure (hourly retries).
    let cardKey = "\(runLabel).\(labelProfile)"

    // A profile of another product (Protect, Security Cloud, organization level) can never run
    // a Jamf Pro schedule, so every retry would fail the same way. Refused before the full
    // recorder opens; like a School backup, it ends the run as a success
    // so the tick does not retry it and no failure webhook is posted. jamf-cli-only reads the
    // cache and sends no command. A case variant (another spelling owns the folder) is refused
    // the same way in every mode. A workspace (a folder with a config.yaml) gets a one-line run
    // record marked refused; a leftover folder, a login with none (Protect) and another
    // spelling's folder get nothing written into them.
    let productRefusal: () -> String? = {
        guard mode != .jamfCLIOnly, configError == nil || mode == .backup else { return nil }
        return CollectRouter.proRunRefusal(
            profile: profile, operation: "Scheduled \(mode.rawValue) run", config: routingConfig)
    }
    if let refusal = caseVariant ?? productRefusal() {
        let message = "[skip] scheduled \(mode.rawValue) run skipped for '\(profile)': "
            + "\(refusal). Not a failure. Exclude this profile from the schedule to stop "
            + "scheduling it."
        fputs(message + "\n", stderr)
        AppLogger.schedule.notice("\(LogRedactor.redact(message), privacy: .private)")
        if ownsFolder, FileManager.default.fileExists(atPath: configURL.path),
           let refusedRecorder = ScheduledRunRecorder(workspace: workspace, label: runLabel) {
            refusedRecorder.record(message)
            refusedRecorder.finish(exitCode: 0, refused: true)
        }
        // Exit 0 so the tick does not retry it, but not silence: one card a day. Never for a case
        // variant, whose webhook and stamp folder are another spelling's (`notifyTargets`).
        await ScheduledRunSignals.notifyScheduledRunFailure(
            config: caseVariant == nil ? routingConfig : nil, profile: profile, mode: mode,
            errorDescription: refusal, recorder: nil, scheduleKey: cardKey)
        return 0
    }

    // Per-run record in <workspace>/automation/ — this is what Run History
    // and the Schedules "Last Run" column read. The launchd stdout/stderr
    // redirect to ~/Library/Logs/JamfReports/<label>/ is unchanged (raw
    // stream capture); the recorder is the structured per-run record.
    // Legacy plists without --label fall back to a profile+mode label so
    // their runs are recorded too.
    let recorder = ScheduledRunRecorder(workspace: workspace, label: runLabel)
    if let recorder {
        AttentionLog.current?.record(
            into: recorder.statusURL, runLog: recorder.logURL.lastPathComponent)
    } else {
        fputs("[warn] could not open run record in automation/logs — run will not appear in Run History\n", stderr)
    }

    // `ReportEngine.collect` returns Void — CollectRouter's typealias and its
    // test spies depend on that — so the two facts that make a bare exit 0 a
    // lie arrive on the log stream instead: this Mac stood down for a peer, or
    // the day's summary never reached disk. Watching the stream is what lets
    // the completion line and the webhook below say which one happened. The
    // caller owns `honesty` so it can read `incomplete` after the run and
    // decide on a same-day retry without the exit code having to change.
    let onLine: @Sendable (CLIBridge.LogLine) -> Void = { line in
        honesty.observe(line.text)
        recorder?.record(line.text)
        if let echo = scheduledRunEcho(line, verbose: verbose) {
            print(isatty(STDOUT_FILENO) == 1 ? CLIRun.terminalSafe(echo) : echo)
        }
    }

    for line in SystemProxy.scheduledRun.runLines {
        let level: CLIBridge.LogLevel = line.hasPrefix("[warn]") ? .warn : .info
        onLine(.init(timestamp: Date(), level: level, text: line))
    }

    if retiredCSVAssisted {
        onLine(.init(timestamp: Date(), level: .info, text:
            "[info] schedule \(runLabel): csv-assisted mode was retired in 2.11; "
            + "ran as jamf-cli-full"))
    }

    // A backup needs only the profile, so it runs; a collect cannot be routed without the file.
    // A backup that reaches Protect warns about the file itself (`backupProtect`).
    if mode != .jamfCLIOnly, mode != .backup, let configError {
        let message = LogRedactor.redact(
            "[error] '\(profile)': config.yaml does not decode, so the product cannot be told "
                + "and nothing ran: \(configError.localizedDescription)")
        fputs(message + "\n", stderr)
        recorder?.record(message)
        recorder?.finish(exitCode: 1)
        await ScheduledRunSignals.notifyScheduledRunFailure(
            config: nil, profile: profile, mode: mode,
            errorDescription: configError.localizedDescription, recorder: nil,
            fallbackNotify: routingNotify, scheduleKey: cardKey)
        return 1
    }

    // Shared workspace: a config.yaml value another Mac changed since this one pinned it is
    // not followed (folders, retention, webhook); the run says which and carries on.
    SharedConfigPin.checkpoint(profile: profile, onLine: onLine)

    // Version-floor preflight (v2.2.0 Phase 3): below the floor a scheduled run stops before
    // any collect/backup, so it never writes data from a binary the app cannot drive.
    // jamf-cli-only generates from cache and never calls jamf-cli, so it is exempt; an absent
    // jamf-cli or an unknown version is also exempt (the collect path handles it).
    if mode != .jamfCLIOnly, let belowVersion = JamfCLIInstaller.installedVersionBelowFloor() {
        let line = JamfCLIInstaller.floorLine(installed: belowVersion, profile: profile)
        fputs(line + "\n", stderr)
        recorder?.record(line)
        recorder?.finish(exitCode: 1)
        await ScheduledRunSignals.notifyScheduledRunFailure(
            config: routingConfig, profile: profile, mode: mode,
            errorDescription: line, recorder: nil, fallbackNotify: routingNotify,
            scheduleKey: cardKey)
        return 1
    }

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
        let backupDetected = ProfileProductType.detect(from: routingConfig, profile: profile)
        guard backupDetected.type == .jamfPro else {
            let message = "[skip] scheduled backup skipped for '\(profile)': "
                + "\(CollectRouter.schoolBackupReason(profile: profile)). Nothing to back up — "
                + "not a failure. Exclude this profile from the backup schedule to stop "
                + "scheduling it."
            print(message)
            recorder?.record(message)
            recorder?.finish(exitCode: 0)
            return 0
        }
        do {
            let bridge = CLIBridge()
            let run = try await bridge.backupRun(
                profile: profile,
                label: "scheduled-\(BackupMaintenance.dateStamp())",
                onLine: onLine
            )
            let exit = run.exit
            // Exit 7 keeps its partial export on disk, so retention has to see
            // it — otherwise partial backups accumulate unpruned forever. The
            // run itself still reports non-success: an incomplete backup is not
            // a restore point, and the row should stay red until it's fixed.
            if CLIBridge.backupOutputIsPrunable(exit: exit) {
                BackupMaintenance.performPostSuccessHousekeeping(
                    profile: profile, justFinished: run.folder, onLine: onLine)
            }
            // Explain the exit code (cause + remediation) instead of a bare
            // integer — same translation the GUI's Backups screen already shows
            // for this identical failure.
            let failureDetail: String? = exit == 0 ? nil : CLIBridge.explainExit(
                exit, operation: "Scheduled backup for '\(profile)'"
            )
            // The Jamf Pro backup stands when only Protect fell short: exit stays 0 and the
            // `[partial]` line, kept inside the log tail Run History reads, makes it Partial.
            // Backup mode never retries within the day, so Partial does not repeat the run.
            let message = failureDetail.map { "[error] " + $0 }
                ?? (honesty.incomplete
                    ? "[partial] scheduled backup for '\(profile)' is incomplete; the lines "
                        + "above say which product's part is missing"
                    : run.folder == nil
                    ? "[ok] scheduled backup ran for '\(profile)' and kept nothing: Jamf Pro was "
                        + "skipped and Jamf Protect left no objects"
                    : "[ok] scheduled backup complete for '\(profile)'")
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
                    errorDescription: failureDetail, recorder: nil, fallbackNotify: routingNotify,
                    scheduleKey: cardKey
                )
            }
            return exit
        } catch {
            let errorDesc = error.localizedDescription
            let message = LogRedactor.redact(
                "[error] scheduled backup failed for '\(profile)': \(errorDesc)")
            fputs(message + "\n", stderr)
            recorder?.record(message)
            recorder?.finish(exitCode: 1)
            await ScheduledRunSignals.notifyScheduledRunFailure(
                config: routingConfig, profile: profile, mode: mode,
                errorDescription: errorDesc, recorder: nil, fallbackNotify: routingNotify,
                scheduleKey: cardKey
            )
            return 1
        }
    }

    do {
        // jamf-cli-only generates from cache only — no collect, no fresh API calls.
        // The other modes all need fresh snapshots.
        if mode != .jamfCLIOnly {
            // PR-23 T-20: the schedule's plist pins the tier set via
            // --tiers. When present, it wins — it's the operator's choice
            // (or the form's mode-derived default). When absent (pre-PR-23
            // plists, or any caller that doesn't pass tiers), fall back to
            // the mode default: snapshot-only → Refresh only (PR-22 T-10),
            // the generate modes → all tiers.
            let resolvedTiers = tiers ?? mode.defaultTiers
            // Route to the correct collect function(s) based on profile product type.
            // Scheduled collects never bypass the Jamf Pro once-per-day guard; a School
            // collect-then-generate forces past School's 12 h cadence (`forcesCollect`).
            try await CollectRouter.run(
                workspace: try WorkspaceID(validating: profile),
                tiers: resolvedTiers,
                force: mode.forcesCollect(
                    for: ProfileProductType.detect(from: routingConfig, profile: profile).type),
                config: routingConfig,
                now: runStart,
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
            let detected = ProfileProductType.detect(from: routingConfig, profile: profile)
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
                    recorder: recorder, now: runStart
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

        let engine = ReportEngine(config: config, dataDir: dataDir, workspace: workspaceID)
        // A School workspace has no Jamf Pro snapshots: the Pro engine would write a
        // workbook with every sheet skipped.
        let isSchool = ProfileProductType.detect(from: config, profile: profile).type == .jamfSchool
        let outputURL = try engine.resolveOutputURL(
            stem: ExportNaming.reportKind(for: .xlsx, schoolMode: isSchool), onLine: onLine)
        // onLine only carries CLIBridge.LogLine progress during generate; per-sheet
        // [fail] lines are raw `print` calls in SheetRegistry and bypass both onLine
        // and the recorder — they reach the console/launchd log only, not Run History.
        let template = FullInstanceTemplate()
        let generated: GeneratedReport
        if isSchool {
            generated = try await ReportEngine.schoolGenerateReport(
                config: config, dataDir: dataDir, outputURL: outputURL, workspace: workspaceID,
                now: runStart, onLine: onLine)
        } else {
            generated = try await engine.generateReport(
                outputURL: outputURL, template: template, now: runStart, onLine: onLine)
        }
        let failures = generated.failures
        if !failures.isEmpty {
            let partialMsg = partialRunMarker(sheetFailures: failures.count)
            recorder?.record(partialMsg)
        }
        // html.with_workbook: a failure is one [warn] line and leaves this run's result alone.
        // There is no School HTML report.
        var htmlURL: URL?
        if !isSchool {
            htmlURL = await engine.writeHTMLWithWorkbook(
                besideWorkbook: outputURL, template: template, onLine: onLine)
        }
        // The run manifest (and its timestamp when configured); a failure is one [warn] line.
        await ReportEngine.sealRun(
            artifacts: [outputURL, htmlURL, generated.csvFolder].compactMap { $0 },
            config: config, profile: profile, onLine: onLine)
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
                config: config, profile: profile, workspace: workspace, recorder: recorder,
                now: runStart
            )
        }
        ScheduledRunSignals.recordConfigHealth(profile: profile, recorder: recorder)
        recorder?.finish(
            exitCode: 0, sheetFailures: failures.count,
            artifacts: [outputURL] + (htmlURL.map { [$0] } ?? [])
                + (generated.csvFolder.map { [$0] } ?? []))
        return 0
    } catch {
        let errorDesc = error.localizedDescription
        let message = LogRedactor.redact("[error] '\(profile)': \(errorDesc)")
        fputs(message + "\n", stderr)
        recorder?.record(message)
        recorder?.finish(exitCode: 1)
        // Post failure digest — best-effort, after recorder is finished so the
        // webhook send latency never blocks the exit path.
        await ScheduledRunSignals.notifyScheduledRunFailure(
            config: routingConfig, profile: profile, mode: mode,
            errorDescription: errorDesc, recorder: nil, fallbackNotify: routingNotify,
            scheduleKey: cardKey
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
    // existing behavior is preserved verbatim. The retired csv-assisted reads as jamf-cli-full.
    let modeArg: String? = {
        guard let idx = args.firstIndex(of: "--mode"), idx + 1 < args.count,
              isFlagValue(args[idx + 1]) else { return nil }
        return args[idx + 1]
    }()
    let mode = modeArg.flatMap(Schedule.RunMode.init(stored:)) ?? .jamfCLIOnly

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
        excludedProfiles: allProfiles ? Array(ProfileService.parseExclusions(excludeArg)) : nil,
        retiredCSVAssisted: modeArg == Schedule.RunMode.retiredCSVAssistedRaw
    )
    // The external scheduler sees the exit code alone — retries are the tick's. Under the
    // tick lock like the tick's own runs; a run it turns away is queued, not failed.
    guard let outcome = await runScheduleExclusively(schedule, verbose: verbose) else {
        return TickRunner.queuedExitCode
    }
    let code = outcome.exitCode
    // External-scheduler path only: the tick posts its own digest once per wake.
    await notifyOverdueSchedulesHeadless(
        profiles: allProfiles ? ProfileService.discoverLocal().map(\.name) : [profile],
        excluding: Set(schedule.excludedProfiles ?? []))
    return code
}

/// One schedule, start to finish: the body every scheduler shares (`--tick`,
/// `--scheduled-run` from an external cron, Run now). Records under the
/// schedule's label; a multi schedule fans out over discovered profiles minus
/// its exclusions and emits the consolidated fleet report for report modes,
/// and succeeds only when every profile did with none incomplete. The retry
/// flag leaves out sources whose failure a same-day retry would only repeat. `skipping` names
/// profiles of a multi schedule a same-day retry leaves alone (`TickScheduler.DueRun`); the
/// outcome lists each profile that ran.
@Sendable
func runSchedule(
    _ schedule: Schedule, verbose: Bool, skipping: Set<String> = []
) async -> ScheduleRunOutcome {
    let label = schedule.launchAgentLabel
    let missing = schedule.mode == .jamfCLIOnly
        ? [] : ProfileService.workspacesMissingJamfCLIProfile()
    guard schedule.isMulti else {
        if await skippedForMissingProfile(schedule.profile, missing: missing) {
            return ScheduleRunOutcome(exitCode: 0, incomplete: false)
        }
        let honesty = CollectHonestyWatcher()
        let start = Date()
        let code = await scheduledRunSingle(
            profile: schedule.profile, mode: schedule.mode, tiers: schedule.tiers,
            verbose: verbose, label: label, honesty: honesty,
            retiredCSVAssisted: schedule.retiredCSVAssisted)
        return ScheduleRunOutcome(
            exitCode: code, incomplete: honesty.incomplete,
            retryCouldHelp: honesty.retryCouldHelp(
                profile: schedule.profile, exitCode: code, since: start))
    }
    let excluded = Set(schedule.excludedProfiles ?? [])
    let discovered = ProfileService.discoverLocal()
    let profiles = ProfileService.runnableProfiles(discovered, excluding: excluded)
    for p in discovered where p.status == .error && !excluded.contains(p.name) {
        let reason = p.unusableReason ?? "not usable"
        fputs("[info] skipping \(p.name): \(reason)\n", stderr)
        // The background item's stderr goes nowhere; the log keeps the reason.
        AppLogger.schedule.notice(
            "skipping \(p.name, privacy: .private): \(reason, privacy: .private)"
        )
    }
    guard !profiles.isEmpty else {
        fputs("[error] \(label ?? "all-profiles"): no local profiles found\n", stderr)
        return ScheduleRunOutcome(exitCode: 1, incomplete: false, considered: [])
    }
    if !excluded.isEmpty {
        fputs("[info] excluding: \(excluded.sorted().joined(separator: ", "))\n", stderr)
    }
    let result = await TickScheduler.runProfiles(
        names: profiles.map(\.name), skipping: skipping
    ) { name in
        if await skippedForMissingProfile(name, missing: missing) { return nil }
        // One watcher per profile: a shared one would carry profile A's
        // stand-down into profile B's completion line.
        let honesty = CollectHonestyWatcher()
        let start = Date()
        let code = await scheduledRunSingle(
            profile: name, mode: schedule.mode, tiers: schedule.tiers,
            verbose: verbose, label: label, honesty: honesty,
            retiredCSVAssisted: schedule.retiredCSVAssisted)
        return ProfileOutcome(
            profile: name, exitCode: code, incomplete: honesty.incomplete,
            retryCouldHelp: honesty.retryCouldHelp(profile: name, exitCode: code, since: start),
            started: start, finished: Date())
    }
    if [.jamfCLIOnly, .jamfCLIFull].contains(schedule.mode) {
        emitConsolidatedReports()
    }
    return ScheduleRunOutcome(
        over: result.ran, ran: result.ran, considered: result.considered)
}

// MARK: - check subcommand

@Sendable
func runCheck(profile: String) -> Int32 {
    guard ProfileService.isValid(profile) else {
        fputs("[error] Invalid profile '\(ConfigSchema.displayText(profile))'\n", stderr)
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
        let environment = EnvironmentProfiles.resolve(config: config, workspace: profile)
        print("[ok] config.yaml decoded successfully")
        // A peer on a shared workspace can write config.yaml, so the value is shown filtered.
        print("[ok] \(environment.isSchool ? "Jamf School" : "Jamf Pro") profile: "
            + (environment.mdm.map(ConfigSchema.displayText) ?? "(not set)"))
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
                fputs(LogRedactor.redact(
                    "[warn] could not read data_dir: \(error.localizedDescription)") + "\n", stderr)
            }
        }

        // The checks above only prove the file parses. Everything an operator
        // actually gets wrong — baselines pointing at absent EAs, malformed alert rules, a workspace
        // on a shared folder with no coordination — lives in the Config Doctor,
        // which the GUI has surfaced since 2.3.0 while `check` did not. Same
        // report, same rules, one implementation.
        return printDoctorReport(ConfigDoctorService.run(profile: profile))
    } catch {
        fputs(LogRedactor.redact("[error] \(error.localizedDescription)") + "\n", stderr)
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
        fputs("[error] Invalid profile '\(ConfigSchema.displayText(profile))'\n", stderr)
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
        // Without this a Jamf Pro workspace prints a [miss] line per School kind and exits 0.
        guard ProfileProductType.detect(from: config, profile: profile).type == .jamfSchool else {
            fputs("[error] '\(profile)' is not a Jamf School workspace (school_cli.enabled is "
                + "not set in its config.yaml); use `jamf-reports check` instead\n", stderr)
            return 1
        }
        print("[ok] config.yaml decoded successfully")
        let schoolSnapshotKinds = ReportEngine.schoolCommandMatrix(profile: profile).map(\.kind)
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
        fputs(LogRedactor.redact("[error] \(error.localizedDescription)") + "\n", stderr)
        return 1
    }
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
    // A host driven only by the CLI has no GUI launch to import legacy plists
    // or register the background item, so every `jamf-reports` invocation does
    // both. Both steps are idempotent.
    WorkspaceStore.bootstrapTickerHeadless()
    await JamfReportsCLI.main(arguments)
}

// MARK: - Entry point

/// The process entry point. The `JamfReports` executable's `main.swift` calls this and nothing
/// else, so every screen and service lives in this library, where Xcode can preview it.
@MainActor
package func runJamfReports() async {
    // Run through the `jamf-reports` link, re-exec the bundled executable (same pid, arguments
    // and streams) so every preference read, `--scheduled-run` and the CLI included, uses the
    // app's domain.
    if let realPath = CLIInstaller.relaunchPath(
        bundleIdentifier: Bundle.main.bundleIdentifier,
        executablePath: Bundle.main.executablePath) {
        var argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) } + [nil]
        execv(realPath, &argv)
        fputs("[warn] could not run \(realPath): \(String(cString: strerror(errno))); "
            + "preferences are read from the jamf-reports domain\n", stderr)
    }

    // Install uncaught-exception handler before any UI or CLI work. Crash logs land at
    // ~/Library/Logs/JamfReports/crash_<timestamp>.log.
    CrashReporter.install()

    let cliArgs = CommandLine.arguments
    // Anchored to position (not a whole-array `contains`) so an option VALUE that
    // happens to equal "--scheduled-run" can't divert the process — mirrors
    // LaunchAgentWriter's plist parser (`args[1] == "--scheduled-run"`) and the
    // routesToCLI check below (`cliArgs[1]`).
    if cliArgs.count > 1, cliArgs[1] == "--tick" {
        // Run now streams this process's output through a pipe; if the GUI quits mid-run, a write
        // must fail with EPIPE instead of killing the tick (and the collect) with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        SystemProxy.installForScheduledRun()
        let code = Task.detached { await runTick(arguments: cliArgs) }
        exit(await code.value)
    } else if cliArgs.count > 1, cliArgs[1] == "--scheduled-run",
       let profile = ProfileService.profileArgument(in: cliArgs) {
        SystemProxy.installForScheduledRun()
        let code = Task.detached { await scheduledRun(profile: profile) }
        let exitCode = await code.value
        exit(exitCode)
    } else if cliArgs.count > 1, JamfReportsCLI.routesToCLI(cliArgs[1]) {
        // Included CLI: `jamf-reports <subcommand> …` (Sources/JamfReports/CLI/). Any word
        // lands here, so ArgumentParser rejects a removed or mistyped subcommand.
        await runIncludedCLI(Array(cliArgs.dropFirst()))
    } else {
        // No arguments, or a launch argument starting with `-` (double-click) → the GUI.
        Localization.useAppLanguage()
        JamfReportsApp.main()
    }
}
