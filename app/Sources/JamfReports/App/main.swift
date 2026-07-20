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
            handle.write(data)
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

/// Pure guard behind `reconcileManagedAutomationHeadless` — extracted so the
/// "unmanaged → no profile discovery, no filesystem I/O" contract is
/// unit-testable without touching `AutomationPolicy.current()` or `UserDefaults`.
func shouldReconcileManagedAutomationHeadless(policy: AutomationPolicy) -> Bool {
    policy.isManaged
}

/// Headless managed-automation self-heal (2.6 field-incident fix). Before
/// this, `ManagedAutomation.reconcile` — including the one-shot RunAtLoad
/// migration and any policy edit (cadence, exclusions, report grouping) —
/// only ever ran from a GUI launch or the Automation screen. A host that
/// never opens the GUI (the whole point of "managed" automation) could sit
/// on stale plists indefinitely; a fleet Mac was found with a weekend-old
/// RunAtLoad:false migration that had never applied. Call EXACTLY ONCE per
/// `--scheduled-run` process, after all per-profile data collection, so
/// reconcile can never delay or fail the run itself.
///
/// No-op when automation isn't managed — bails before any profile discovery
/// or filesystem I/O, matching `WorkspaceStore.catchUpCollectIfNeeded`'s
/// early-exit shape. `currentLabel` is this process's OWN LaunchAgent label
/// (threaded from `--label`); reconcile self-skips bootout/bootstrap for it —
/// see `ManagedAutomation.reconcile(currentLabel:)`. Best-effort: reconcile
/// never throws, and every action failure is logged + captured in the
/// returned outcomes rather than surfaced to the caller.
@Sendable
func reconcileManagedAutomationHeadless(
    currentLabel: String?,
    policy: AutomationPolicy = AutomationPolicy.current()
) async {
    guard shouldReconcileManagedAutomationHeadless(policy: policy) else { return }
    _ = await ManagedAutomation.reconcileWithMigration(policy: policy, currentLabel: currentLabel)
}

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
@Sendable
private func notifyOverdueSchedulesHeadless(profiles: [String]) async {
    let overdue = AutomationHealth.evaluate(inputs: LaunchAgentService.healthInputs())
        .filter { $0.kind == .overdue }
    guard !overdue.isEmpty else { return }
    guard let resolved = firstUsableNotify(in: profiles) else { return }
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
            try? LaunchAgentLogRotator.rotateIfNeeded(logURL: entry)
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

    let onLine: @Sendable (CLIBridge.LogLine) -> Void = { line in
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

    // Backup mode (v2.2.0): export configuration objects; no collect, no
    // generate. Retention prunes scheduled backups beyond the newest 10 and
    // sweeps abandoned .tmp-* staging dirs.
    if mode == .backup {
        do {
            let bridge = CLIBridge()
            let exit = try await bridge.backup(
                profile: profile,
                label: "scheduled-\(BackupMaintenance.dateStamp())",
                onLine: onLine
            )
            if exit == 0 {
                BackupMaintenance.performPostSuccessHousekeeping(profile: profile, onLine: onLine)
            }
            let message = exit == 0
                ? "[ok] scheduled backup complete for '\(profile)'"
                : "[error] scheduled backup failed for '\(profile)': exit \(exit)"
            if exit == 0 { print(message) } else { fputs(message + "\n", stderr) }
            recorder?.record(message)
            recorder?.finish(exitCode: exit)
            return exit
        } catch {
            let message = "[error] scheduled backup failed for '\(profile)': \(error.localizedDescription)"
            fputs(message + "\n", stderr)
            recorder?.record(message)
            recorder?.finish(exitCode: 1)
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

    // Load config once, before collect (routing needs it) and before generate.
    // Failure degrades collect routing to Jamf Pro and still fails generate
    // with the real error (ConfigLoader.LoadError) so the recorded run shows
    // a meaningful message. nil config in routing logs loudly and uses Pro.
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
            let trendsSuffix = detected.type == .jamfPro ? " — Trends updated" : ""
            let message = "[ok] scheduled snapshot complete for '\(profile)'\(trendsSuffix)"
            print(message)
            recorder?.record(message)
            await ScheduledRunSignals.notifyScheduledRun(
                config: routingConfig, profile: profile, mode: mode,
                artifact: nil, recorder: recorder
            )
            await ScheduledRunSignals.notifyMetricAlerts(
                config: routingConfig, profile: profile, workspace: workspace, recorder: recorder
            )
            recorder?.finish(exitCode: 0)
            return 0
        }

        let config = try routingConfig ?? ConfigLoader.load(from: configURL)
        let dataDir = try WorkspacePaths.dataDir(for: profile)
        let engine = ReportEngine(config: config, dataDir: dataDir)
        let outputURL = engine.resolveOutputURL(stem: "report", profile: profile)
        // Thread onLine so per-sheet [fail] lines reach the recorder and Run History,
        // not just the console. The recorder is Sendable (NSLock-backed); the closure
        // captures it as an optional so the recorder being nil is a no-op.
        let failures = try await engine.generate(
            csvURL: resolvedCSV,
            outputURL: outputURL,
            onLine: onLine
        )
        if !failures.isEmpty {
            let partialMsg = "[partial] \(failures.count) sheet failure(s) — see lines above"
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
        // summary isn't "just produced" — skip alerting for it.
        if mode != .jamfCLIOnly {
            await ScheduledRunSignals.notifyMetricAlerts(
                config: config, profile: profile, workspace: workspace, recorder: recorder
            )
        }
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
        guard let idx = args.firstIndex(of: "--mode"), idx + 1 < args.count else {
            return .jamfCLIOnly
        }
        return Schedule.RunMode(rawValue: args[idx + 1]) ?? .jamfCLIOnly
    }()

    // PR-23 T-20: --tiers <csv> pins the collect tier set. Absent (pre-PR-23
    // plists) → nil, and scheduledRunSingle falls back to the mode default.
    // Unknown tokens are dropped; an all-unknown CSV resolves to nil.
    let tiers: Set<CollectionTier>? = {
        guard let idx = args.firstIndex(of: "--tiers"), idx + 1 < args.count else {
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
              LaunchAgentWriter.isValidLabel(args[idx + 1]) else {
            return nil
        }
        return args[idx + 1]
    }()

    if allProfiles {
        // --exclude-profiles <csv> drops profiles from the run-time-discovered
        // set (run-time exclusion — never a positive --multi-profiles list, so
        // a managed all-profiles agent still picks up profiles added later).
        let excludeArg: String? = {
            guard let idx = args.firstIndex(of: "--exclude-profiles"), idx + 1 < args.count else {
                return nil
            }
            return args[idx + 1]
        }()
        let excluded = ProfileService.parseExclusions(excludeArg)
        let profiles = ProfileService.applyingExclusions(
            ProfileService.discoverLocal(), excluding: excluded
        )
        guard !profiles.isEmpty else {
            fputs("[error] --all-profiles: no local profiles found\n", stderr)
            return 1
        }
        if !excluded.isEmpty {
            fputs("[info] --all-profiles excluding: \(excluded.sorted().joined(separator: ", "))\n", stderr)
        }
        var anyFailed = false
        for p in profiles {
            let code = await scheduledRunSingle(
                profile: p.name, mode: mode, tiers: tiers, verbose: verbose, label: label
            )
            if code != 0 { anyFailed = true }
        }
        // v2.2.0 Phase 4: after the per-profile reports run, emit one
        // consolidated fleet report per configured group. Only for
        // report-generating modes — the freshness/scan snapshot agents skip it.
        if mode == .jamfCLIOnly || mode == .jamfCLIFull || mode == .csvAssisted {
            emitConsolidatedReports()
        }
        // Managed-automation self-heal — once per process, after all
        // per-profile data collection, so a policy edit or the RunAtLoad
        // migration applies on hosts that never open the GUI.
        await reconcileManagedAutomationHeadless(currentLabel: label)
        // Dead-man overdue digest for headless hosts — once per process, after
        // all per-profile work.
        await notifyOverdueSchedulesHeadless(profiles: profiles.map(\.name))
        return anyFailed ? 1 : 0
    }

    let code = await scheduledRunSingle(
        profile: profile, mode: mode, tiers: tiers, verbose: verbose, label: label
    )
    // Managed-automation self-heal — once per process, before the overdue digest
    // so a reconciled agent's next-fire time is reflected in that same pass.
    await reconcileManagedAutomationHeadless(currentLabel: label)
    await notifyOverdueSchedulesHeadless(profiles: [profile])
    return code
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
        return 0
    } catch {
        fputs("[error] \(error.localizedDescription)\n", stderr)
        return 1
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
if cliArgs.contains("--scheduled-run"),
   let profileIdx = cliArgs.firstIndex(of: "--profile"),
   profileIdx + 1 < cliArgs.count {
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
