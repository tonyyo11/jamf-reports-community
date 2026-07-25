import Foundation
import Darwin
import OSLog

/// Discovers `~/Library/LaunchAgents/com.github.tonyyo11.jamf-reports-community.*.plist`
/// files and parses them into `Schedule` model objects.
enum LaunchAgentService {

    struct LegacyCleanupResult: Sendable {
        let removedLabels: [String]

        var message: String? {
            guard !removedLabels.isEmpty else { return nil }
            return "Removed \(removedLabels.count) legacy com.tonyyo.jrc LaunchAgent"
                + (removedLabels.count == 1 ? "." : "s.")
        }
    }

    /// Where macOS UserAgents live. We never touch system-wide LaunchDaemons.
    static let agentsDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents", isDirectory: true)

    /// All Jamf Reports LaunchAgent plist files.
    static func list() -> [Schedule] {
        launchAgentEntries()
            .filter { $0.lastPathComponent.hasPrefix("\(LaunchAgentWriter.labelPrefix).") }
            .filter { $0.pathExtension == "plist" }
            .compactMap(parse)
            .sorted { $0.name < $1.name }
    }

    /// LaunchAgent labels whose `ProgramArguments[0]` (executable) no longer
    /// exists on disk — typically because the .app bundle was rebuilt at a
    /// different path (different worktree, different release archive).
    /// macOS will queue these for execution at the next trigger and they will
    /// fail at launch with `posix_spawn` ENOENT, polluting the
    /// `~/Library/Logs/JamfReports/<label>/stderr.log` file with a
    /// confusing path-not-found error.
    ///
    /// - Parameter dir: Directory to scan. Defaults to the user's
    ///   `~/Library/LaunchAgents`. Tests pass a temp dir.
    /// - Returns: Sorted list of plist labels whose recorded executable is
    ///   missing on disk. Empty when every JRC plist's executable still
    ///   exists or when there are no JRC plists at all.
    static func staleExecutableLabels(in dir: URL = agentsDir) -> [String] {
        let prefix = "\(LaunchAgentWriter.labelPrefix)."
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let fm = FileManager.default
        return entries
            .filter { $0.pathExtension == "plist" }
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .compactMap { url -> String? in
                guard let data = try? Data(contentsOf: url),
                      let plist = try? PropertyListSerialization
                          .propertyList(from: data, format: nil) as? [String: Any],
                      let label = plist["Label"] as? String,
                      LaunchAgentWriter.isValidLabel(label),
                      let args = plist["ProgramArguments"] as? [String],
                      let executable = args.first,
                      !executable.isEmpty else {
                    return nil
                }
                return fm.fileExists(atPath: executable) ? nil : label
            }
            .sorted()
    }

    /// LaunchAgent plist labels that look like JRC schedules but cannot be
    /// unambiguously attributed to a current profile slug — typically
    /// because they were written before S-03 tightened
    /// `ProfileService.isValid`, so they encode a dotted profile name
    /// (`com.…jamf-reports-community.tenant-1.prod.daily`).
    ///
    /// Surfaced so the caller can log a one-shot migration warning per
    /// label after PR-3. The plist files are left on disk untouched —
    /// the user should `launchctl bootout` and remove them manually, or
    /// the upcoming UI surfacing pass (tracked in BACKLOG) will offer a
    /// "remove legacy schedule" action.
    ///
    /// - Parameter dir: Directory to scan. Defaults to the user's
    ///   `~/Library/LaunchAgents`. Tests pass a temp dir to avoid
    ///   touching the real home directory.
    static func dottedLegacyAgents(in dir: URL = agentsDir) -> [String] {
        let prefix = "\(LaunchAgentWriter.labelPrefix)."
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { $0.pathExtension == "plist" }
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .compactMap { url -> String? in
                let label = plistLabel(url) ?? url.deletingPathExtension().lastPathComponent
                guard label.hasPrefix(prefix) else { return nil }
                let tail = String(label.dropFirst(prefix.count))
                // Multi labels are well-formed by construction; skip.
                if tail.hasPrefix("multi.") { return nil }
                let parts = tail.components(separatedBy: ".")
                // After PR-3 a well-formed non-multi label has exactly 2
                // post-prefix components (profile + slug). More than 2
                // means a dotted profile name slipped through the old
                // validator — flag for migration.
                return parts.count > 2 ? label : nil
            }
            .sorted()
    }

    /// Delete old Swift-owned `com.tonyyo.jrc.*` plists once at app launch.
    static func cleanupLegacyAgents() -> LegacyCleanupResult {
        let legacyURLs = launchAgentEntries()
            .filter { $0.lastPathComponent.hasPrefix("\(LaunchAgentWriter.legacyLabelPrefix).") }
            .filter { $0.pathExtension == "plist" }

        var removed: [String] = []
        for url in legacyURLs {
            let label = plistLabel(url) ?? url.deletingPathExtension().lastPathComponent
            guard label.hasPrefix("\(LaunchAgentWriter.legacyLabelPrefix).") else { continue }
            _ = bootout(label)
            do {
                try FileManager.default.removeItem(at: url)
                removed.append(label)
            } catch {
                continue
            }
        }
        return LegacyCleanupResult(removedLabels: removed.sorted())
    }

    /// Remove generated Jamf Reports LaunchAgents for a profile. Used when
    /// leaving demo mode so synthetic demo schedules cannot appear in live mode.
    static func removeAgents(profile: String) -> [String] {
        guard ProfileService.isValid(profile) else {
            // Dotted legacy profile names (e.g. "tenant.prod") contain a period and
            // fail the current validator. Those plists cannot be matched by prefix and
            // must be removed manually via `launchctl bootout` + `rm`.
            AppLogger.schedule.warning(
                // swiftlint:disable:next line_length
                "LaunchAgentService.removeAgents: profile \(profile, privacy: .private) failed validation — dotted legacy profiles cannot be removed by this path and need manual launchctl bootout cleanup"
            )
            return []
        }
        let prefix = "\(LaunchAgentWriter.labelPrefix).\(profile)."
        let urls = launchAgentEntries()
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .filter { $0.pathExtension == "plist" }

        var removed: [String] = []
        for url in urls {
            guard let label = plistLabel(url),
                  LaunchAgentWriter.isValidLabel(label),
                  label.hasPrefix(prefix) else {
                continue
            }
            _ = bootout(label)
            do {
                try FileManager.default.removeItem(at: url)
                removed.append(label)
            } catch {
                continue
            }
        }
        return removed.sorted()
    }

    /// Result of a consolidation removal.
    struct ConsolidationRemovalResult: Sendable {
        let removed: [String]
        let rejected: [String]
        let archiveDir: URL?
    }

    /// Archive, then remove, the hand-built (NON-managed) LaunchAgents named by
    /// `labels` — the consolidation path that retires schedules the managed
    /// policy now duplicates.
    ///
    /// Safety, in order:
    /// 1. Any reserved managed label (`ManagedAutomation.owns`) is REFUSED — the
    ///    exact inverse of the managed-reconcile guard, so this path can only
    ///    ever retire a user-built agent the operator confirmed.
    /// 2. Each plist is copied to
    ///    `<workspacesRoot>/_archived-launchagents/<label>.<ts>.plist` BEFORE
    ///    bootout + delete (recoverable, matching the snapshot retention
    ///    archive-not-delete model). A failed archive aborts that label's
    ///    removal — recoverability first, nothing is lost on a mis-click.
    static func archiveAndRemove(labels: [String]) -> ConsolidationRemovalResult {
        let archiveDir = ProfileService.workspacesRoot()
            .appendingPathComponent("_archived-launchagents", isDirectory: true)
        var removed: [String] = []
        var rejected: [String] = []
        var didArchive = false
        for label in labels {
            guard !ManagedAutomation.owns(label) else {
                AppLogger.schedule.warning(
                    "archiveAndRemove refused managed label \(label, privacy: .public)")
                rejected.append(label)
                continue
            }
            guard LaunchAgentWriter.isValidLabel(label), let url = agentURL(forLabel: label) else {
                rejected.append(label)
                continue
            }
            guard archivePlist(at: url, label: label, into: archiveDir) else {
                rejected.append(label)  // archive failed → do not delete.
                continue
            }
            didArchive = true
            let bootoutStatus = bootout(label)
            if bootoutStatus != 0 {
                // Non-zero is usually "no such process" — the agent was never
                // bootstrapped this session — and the plist removal below still
                // retires it. Logged so a genuinely stuck agent is diagnosable.
                AppLogger.schedule.info(
                    "bootout \(label, privacy: .public) exited \(bootoutStatus) (agent likely not loaded; plist removed regardless)")
            }
            do {
                try FileManager.default.removeItem(at: url)
                removed.append(label)
            } catch {
                rejected.append(label)
            }
        }
        return ConsolidationRemovalResult(
            removed: removed.sorted(), rejected: rejected.sorted(),
            archiveDir: didArchive ? archiveDir : nil
        )
    }

    /// Resolve the on-disk plist URL whose `Label` matches `label`. Prefers the
    /// `<label>.plist` filename convention, then falls back to scanning.
    ///
    /// - Parameter dir: Directory to search. Defaults to the real
    ///   `~/Library/LaunchAgents`; `kickstartNow` tests pass a temp dir.
    private static func agentURL(forLabel label: String, in dir: URL = agentsDir) -> URL? {
        let direct = dir.appendingPathComponent("\(label).plist")
        if FileManager.default.fileExists(atPath: direct.path), plistLabel(direct) == label {
            return direct
        }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.first { $0.pathExtension == "plist" && plistLabel($0) == label }
    }

    private static let archiveTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()

    /// CLI flags whose following ProgramArguments value is a secret and must be
    /// redacted before the plist is archived. Only `--notify` carries one today:
    /// the Python launchagent writer embeds a Teams/Slack incoming-webhook URL
    /// (a posting credential) in ProgramArguments. The archive lives under the
    /// workspaces root, which operators commonly host on a cloud share — so the
    /// URL is scrubbed in the COPY. The live plist in LaunchAgents is untouched;
    /// restoring it means re-adding the webhook.
    ///
    /// MAINTENANCE CONTRACT: this set must stay in sync with the credential-bearing
    /// flag vocabulary of `LaunchAgentWriter.nativeSingleWrite` and
    /// `nativeMultiWrite`. Any future flag that embeds a credential (API key,
    /// webhook URL, bearer token, etc.) in ProgramArguments MUST be added here,
    /// or it will ship unredacted into workspace archives (potentially on a
    /// cloud share). One flag per entry; the flag name only — not the value slot.
    private static let secretArgFlags: Set<String> = ["--notify"]

    private static func archivePlist(at url: URL, label: String, into dir: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = archiveTimestampFormatter.string(from: Date())
            let dest = dir.appendingPathComponent("\(label).\(stamp).plist")
            if let redacted = redactedPlistData(at: url) {
                try redacted.write(to: dest, options: .atomic)
            } else {
                try FileManager.default.copyItem(at: url, to: dest)
            }
            return true
        } catch {
            AppLogger.schedule.error(
                "archivePlist failed for \(label, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Returns plist `Data` with secret arg values redacted, or nil when the
    /// plist has no secrets to redact or can't be parsed — in which case the
    /// caller copies it verbatim, preserving behavior for non-secret plists.
    /// Internal (not private) so the redaction is directly unit-testable.
    static func redactedPlistData(at url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url),
              let parsed = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil),
              var plist = parsed as? [String: Any],
              var args = plist["ProgramArguments"] as? [String] else {
            return nil
        }
        var redacted = false
        var i = 0
        while i + 1 < args.count {
            if secretArgFlags.contains(args[i]) {
                args[i + 1] = "<redacted-on-archive>"
                redacted = true
                i += 2
            } else {
                i += 1
            }
        }
        guard redacted else { return nil }
        plist["ProgramArguments"] = args
        return try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
    }

    // MARK: - Private

    private static func launchAgentEntries() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: agentsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    /// Parse one plist into a Schedule. Returns nil if the plist is malformed
    /// or the label doesn't match the expected naming convention.
    static func parse(_ url: URL) -> Schedule? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization
                .propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String,
              LaunchAgentWriter.isValidLabel(label) else {
            return nil
        }

        guard let labelParts = profileAndSlug(from: label) else { return nil }
        let args = plist["ProgramArguments"] as? [String] ?? []
        let enabled = !((plist["Disabled"] as? Bool) ?? false)
        let cadence = describeCadence(plist["StartCalendarInterval"])
        let mode = runMode(from: args) ?? .jamfCLIOnly
        let statusURL = labelParts.isMulti
            ? multiStatusFileURL(from: args, label: label)
            : statusFileURL(from: args, profile: labelParts.profile, label: label)
        let runStatus = labelParts.isMulti
            ? readMultiRunStatus(from: statusURL, label: label)
            : readRunStatus(from: statusURL, profile: labelParts.profile)
        let logSummary = readLogSummary(
            from: plist,
            profile: labelParts.profile,
            label: label,
            isMulti: labelParts.isMulti
        )
        let lastDate = runStatus?.finishedAt ?? logSummary.date

        return Schedule(
            name: humanName(from: labelParts.slug, mode: mode),
            profile: labelParts.isMulti ? "" : labelParts.profile,
            schedule: cadence,
            cadence: "custom",
            mode: mode,
            next: nextRunText(from: plist["StartCalendarInterval"], enabled: enabled),
            last: lastDate.map(FileDisplay.date) ?? "—",
            lastStatus: lastStatus(from: runStatus, logSummary: logSummary),
            artifacts: runStatus?.artifacts ?? [],
            enabled: enabled,
            launchAgentLabel: label,
            multiTarget: labelParts.isMulti ? (multiTarget(from: args) ?? MultiTarget(scope: .all)) : nil,
            tiers: tiers(from: args)
        )
    }

    // MARK: - Dead-man switch (2.6 trust trio #2)

    /// The raw fields the overdue evaluator needs for one scheduled agent —
    /// deliberately smaller than `Schedule` (which carries only display strings
    /// for last/next and so can't answer "should it have fired by now?").
    struct ScheduleHealthInput: Sendable, Equatable {
        let label: String
        let displayName: String
        let enabled: Bool
        /// Owning profile slug for a per-profile (non-multi) agent; "" for multi.
        /// Used to scope the dead-man banner so a DIFFERENT profile's agent
        /// doesn't surface as this workspace's own.
        let profile: String
        /// True for the global all-profiles managed/multi agents, which cover
        /// every profile and so surface on each profile's Overview.
        let isMulti: Bool
        /// Most recent time this schedule should have fired at/before the probe.
        let expectedFire: Date?
        /// Newest run artifact's finish time, if any run has ever recorded one.
        let lastRunFinishedAt: Date?
        /// Newest run artifact's success flag (nil when no artifact recorded).
        let lastRunSuccess: Bool?
        /// Newest run artifact's process exit code, when the record carries a
        /// numeric one. Drives the plain-language cause on a failing row;
        /// nil falls back to the generic "reported failure" wording.
        let lastRunExitCode: Int32?

        init(
            label: String,
            displayName: String,
            enabled: Bool,
            profile: String = "",
            isMulti: Bool = false,
            expectedFire: Date?,
            lastRunFinishedAt: Date?,
            lastRunSuccess: Bool?,
            lastRunExitCode: Int32? = nil
        ) {
            self.label = label
            self.displayName = displayName
            self.enabled = enabled
            self.profile = profile
            self.isMulti = isMulti
            self.expectedFire = expectedFire
            self.lastRunFinishedAt = lastRunFinishedAt
            self.lastRunSuccess = lastRunSuccess
            self.lastRunExitCode = lastRunExitCode
        }
    }

    /// Lightweight per-agent inputs for the overdue/failing evaluator. Reuses the
    /// same plist + status-JSON parsing as `parse`, but returns the RAW expected
    /// fire and last-run finish/success instead of formatted strings, without
    /// changing `Schedule`'s public shape. `now` is injected so the "expected
    /// fire" is deterministic under test.
    ///
    /// - Parameter dir: directory to scan (tests pass a temp dir).
    static func healthInputs(in dir: URL = agentsDir, now: Date = Date()) -> [ScheduleHealthInput] {
        scannedHealthInputs(in: dir, now: now, statusProfile: nil)
    }

    /// Shared plist scan behind both `healthInputs(in:)` and `healthInputs(for:)`.
    ///
    /// `statusProfile` controls how a MULTI (managed, all-profiles) agent's run
    /// status is resolved:
    /// - `nil` (the fleet-wide/profile-less caller, `healthInputs(in:)`):
    ///   preserves the pre-existing cross-profile "newest finish wins" fallback
    ///   (`newestMultiRunStatus`) — used only for `.overdue` detection by the
    ///   headless dead-man digest, where "did this schedule fire recently
    ///   ANYWHERE" is the correct question.
    /// - non-nil (`healthInputs(for:)`): scopes the fallback to THAT profile's
    ///   own `<workspace>/automation/<label>_status.json` — never another
    ///   profile's. A multi agent's `.failing` state must reflect what
    ///   happened for the profile being evaluated; otherwise a different
    ///   profile's later (successful) run of the same shared schedule can mask
    ///   this profile's genuine failure on its own Overview/Automation screen.
    private static func scannedHealthInputs(
        in dir: URL, now: Date, statusProfile: String?
    ) -> [ScheduleHealthInput] {
        let prefix = "\(LaunchAgentWriter.labelPrefix)."
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { $0.pathExtension == "plist" }
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .compactMap { healthInput(for: $0, now: now, statusProfile: statusProfile) }
            .sorted { $0.displayName < $1.displayName }
    }

    private static func healthInput(
        for url: URL, now: Date, statusProfile: String?
    ) -> ScheduleHealthInput? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization
                .propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String,
              LaunchAgentWriter.isValidLabel(label),
              let parts = profileAndSlug(from: label) else {
            return nil
        }
        let args = plist["ProgramArguments"] as? [String] ?? []
        let enabled = !((plist["Disabled"] as? Bool) ?? false)
        let mode = runMode(from: args) ?? .jamfCLIOnly
        let expectedFire = lastScheduledFireDate(from: plist["StartCalendarInterval"], before: now)
        let runStatus: ParsedRunStatus?
        if parts.isMulti {
            runStatus = multiRunStatus(label: label, args: args, statusProfile: statusProfile)
        } else {
            let statusURL = statusFileURL(from: args, profile: parts.profile, label: label)
            runStatus = readRunStatus(from: statusURL, profile: parts.profile)
        }
        return ScheduleHealthInput(
            label: label,
            displayName: humanName(from: parts.slug, mode: mode),
            enabled: enabled,
            profile: parts.profile,
            isMulti: parts.isMulti,
            expectedFire: expectedFire,
            lastRunFinishedAt: runStatus?.finishedAt,
            lastRunSuccess: runStatus?.success,
            lastRunExitCode: runStatus?.exitCode
        )
    }

    /// Resolve a MULTI (managed, all-profiles) agent's run status.
    ///
    /// Managed all-profiles agents carry no `--status-file`, so
    /// `readMultiRunStatus` (which requires one) always yields nil for them;
    /// the run instead records status per profile at
    /// `<workspace>/automation/<label>_status.json`.
    ///
    /// - `statusProfile` provided: read ONLY that profile's own record —
    ///   label-exact AND profile-exact, never a different profile's file for
    ///   the same label. A failing agent stays failing until this profile's
    ///   own next run of it succeeds (or the overdue branch takes over).
    /// - `statusProfile` nil: fall back to scanning every local profile's
    ///   record for this label and take the newest finish (`newestMultiRunStatus`)
    ///   — pinned by `testMultiHealthInputPicksNewestProfileStatus` — so a
    ///   managed agent isn't read as perpetually overdue by the fleet-wide,
    ///   profile-less caller.
    private static func multiRunStatus(
        label: String, args: [String], statusProfile: String?
    ) -> ParsedRunStatus? {
        let statusURL = multiStatusFileURL(from: args, label: label)
        if let status = readMultiRunStatus(from: statusURL, label: label) {
            return status
        }
        if let statusProfile {
            return readRunStatus(
                from: statusFileURL(from: [], profile: statusProfile, label: label),
                profile: statusProfile
            )
        }
        return newestMultiRunStatus(label: label)
    }

    /// Health inputs relevant to `profile`'s Overview: the global managed
    /// (`isMulti`) agents surface on every profile (managed collection covers
    /// this profile too), PLUS this profile's own user-built agents. A
    /// DIFFERENT profile's hand-built agents are dropped so they don't bleed
    /// onto this workspace's Overview as if they were its own.
    ///
    /// A multi agent's run status here is resolved from `profile`'s OWN
    /// status file only (see `multiRunStatus`) — never a different local
    /// profile's — so e.g. "Managed Freshness" failing for this profile can
    /// never be masked by another profile's later successful run of the same
    /// shared schedule.
    static func healthInputs(
        for profile: String, in dir: URL = agentsDir, now: Date = Date()
    ) -> [ScheduleHealthInput] {
        filterHealthInputs(
            scannedHealthInputs(in: dir, now: now, statusProfile: profile),
            forProfile: profile
        )
    }

    /// Pure filter behind `healthInputs(for:)` — unit-tested directly.
    static func filterHealthInputs(
        _ inputs: [ScheduleHealthInput], forProfile profile: String
    ) -> [ScheduleHealthInput] {
        inputs.filter { $0.isMulti || $0.profile == profile }
    }

    // MARK: - Run now (health-row kickstart)

    /// Outcome of `kickstartNow`, including whether the bootstrap fallback was
    /// needed — surfaced for logging without changing the simple success Bool
    /// the UI acts on.
    struct KickstartOutcome: Sendable, Equatable {
        let succeeded: Bool
        let usedBootstrapFallback: Bool
    }

    /// One-click "Run now" for a failing/overdue Automation Health row:
    /// immediately re-executes an INSTALLED agent's job via
    /// `launchctl kickstart -k gui/<uid>/<label>`. launchd runs the real job
    /// with its exact plist arguments, so the run records under the correct
    /// label and writes the correct status file — a success genuinely clears
    /// the row's health state.
    ///
    /// If kickstart fails — commonly because the plist is on disk but was
    /// never `launchctl bootstrap`ed (e.g. after a file-only self-heal
    /// write) — falls back to bootstrapping the plist first, then retries
    /// kickstart once. Never throws; a failure is just a `false` the caller
    /// surfaces as a toast.
    ///
    /// `runLaunchctl` is injectable so tests can assert the exact argv
    /// without touching real launchctl; production uses `defaultRunLaunchctl`.
    ///
    /// - Parameter dir: Directory to locate the agent's plist in for the
    ///   bootstrap fallback. Defaults to the real `~/Library/LaunchAgents`;
    ///   tests pass a temp dir.
    static func kickstartNow(
        label: String,
        in dir: URL = agentsDir,
        runLaunchctl: @Sendable ([String]) async -> Int32 = defaultRunLaunchctl
    ) async -> KickstartOutcome {
        guard LaunchAgentWriter.isValidLabel(label) else {
            return KickstartOutcome(succeeded: false, usedBootstrapFallback: false)
        }
        let target = "gui/\(getuid())/\(label)"
        if await runLaunchctl(["kickstart", "-k", target]) == 0 {
            return KickstartOutcome(succeeded: true, usedBootstrapFallback: false)
        }
        guard let url = agentURL(forLabel: label, in: dir) else {
            return KickstartOutcome(succeeded: false, usedBootstrapFallback: false)
        }
        guard await runLaunchctl(["bootstrap", "gui/\(getuid())", url.path]) == 0 else {
            return KickstartOutcome(succeeded: false, usedBootstrapFallback: true)
        }
        let succeeded = await runLaunchctl(["kickstart", "-k", target]) == 0
        return KickstartOutcome(succeeded: succeeded, usedBootstrapFallback: true)
    }

    /// Production launchctl invocation for `kickstartNow` — mirrors
    /// `LaunchAgentWriter`'s private async launchctl helper.
    static let defaultRunLaunchctl: @Sendable ([String]) async -> Int32 = { args in
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = args
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            p.terminationHandler = { proc in cont.resume(returning: proc.terminationStatus) }
            do {
                try p.run()
            } catch {
                AppLogger.cli.error(
                    """
                    launchctl \(args.first ?? "", privacy: .public) launch failed: \
                    \(error.localizedDescription, privacy: .private)
                    """
                )
                cont.resume(returning: -1)
            }
        }
    }

    private static func plistLabel(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization
                .propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return plist["Label"] as? String
    }

    private struct LabelParts {
        let profile: String
        let slug: String
        let isMulti: Bool
    }

    private static func profileAndSlug(from label: String) -> LabelParts? {
        let prefix = "\(LaunchAgentWriter.labelPrefix)."
        guard label.hasPrefix(prefix) else { return nil }
        let tail = String(label.dropFirst(prefix.count))
        if tail.hasPrefix("multi.") {
            let slug = String(tail.dropFirst("multi.".count))
            guard !slug.isEmpty else { return nil }
            return LabelParts(profile: "", slug: slug, isMulti: true)
        }
        let parts = tail.components(separatedBy: ".")
        // S-03: after PR-3 every valid profile and slug is dot-free, so a
        // well-formed non-multi label has exactly 2 components after the
        // prefix (profile + slug). A label with `parts.count > 2` is a
        // legacy plist written before the validator was tightened — the
        // old behavior was to take `parts.first` as the profile and
        // join the rest as the slug, which silently re-attributed the
        // plist to a different (valid-by-itself) profile. Reject so the
        // Schedules UI cannot operate on a mis-attributed legacy plist;
        // the file on disk is preserved and surfaced via
        // `LaunchAgentService.dottedLegacyAgents()` for migration.
        guard parts.count == 2 else { return nil }
        guard let profile = parts.first, ProfileService.isValid(profile) else { return nil }
        let slug = parts[1]
        guard !slug.isEmpty else { return nil }
        return LabelParts(profile: profile, slug: slug, isMulti: false)
    }

    private static func multiTarget(from args: [String]) -> MultiTarget? {
        let flags: [String]
        // Legacy arm: pre-PR-20 plists written by the old Python CLI used the `multi`
        // keyword as args[1]. Load-bearing for any plist created before the native
        // LaunchAgentWriter was introduced — do NOT remove.
        if args.count >= 2, args[1] == "multi" {
            flags = Array(args.dropFirst(2).prefix { $0 != "--" })
        // Legacy arm: pre-PR-20 plists written by the Python CLI's `multi-launchagent-run`
        // subcommand embedded the subcommand name literally. Load-bearing for those
        // plists — do NOT remove.
        } else if let runIndex = args.firstIndex(of: "multi-launchagent-run") {
            flags = Array(args.dropFirst(runIndex + 1))
        } else {
            return nil
        }
        var scope: MultiTarget.Scope = .all
        var sequential = false
        var i = 0
        while i < flags.count {
            switch flags[i] {
            // Legacy aliases: the native writer only emits `--sequential`, but pre-PR-20
            // plists may carry `--multi-sequential`. Both arms are load-bearing.
            case "--sequential", "--multi-sequential":
                sequential = true
            // Legacy aliases: native writer emits `--filter`; pre-PR-20 plists may carry
            // `--multi-filter`. Both arms are load-bearing.
            case "--filter", "--multi-filter":
                if i + 1 < flags.count {
                    scope = .filter(flags[i + 1])
                    i += 1
                }
            // Legacy aliases: native writer emits `--profiles`; pre-PR-20 plists may carry
            // `--multi-profiles`. Both arms are load-bearing.
            case "--profiles", "--multi-profiles":
                if i + 1 < flags.count {
                    let profiles = flags[i + 1]
                        .split(separator: ",")
                        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { ProfileService.isValid($0) }
                    if !profiles.isEmpty {
                        scope = .list(profiles)
                    }
                    i += 1
                }
            default:
                break
            }
            i += 1
        }
        return MultiTarget(scope: scope, sequential: sequential)
    }

    private static func runMode(from args: [String]) -> Schedule.RunMode? {
        guard let idx = args.firstIndex(of: "--mode"), idx + 1 < args.count else { return nil }
        return Schedule.RunMode(rawValue: args[idx + 1])
    }

    /// Parse `--tiers <csv>` into a `CollectionTier` set (PR-23 T-19).
    ///
    /// Returns `nil` when the flag is absent — pre-PR-23 plists omit it and
    /// `main.swift` defaults a missing tier set to all tiers.
    ///
    /// Unknown tier tokens are dropped with a warning rather than failing
    /// the parse, so a plist written by a newer build still loads on an
    /// older one. If *every* token is unknown (corruption, or a cross-
    /// version rename), the whole flag is treated as absent (`nil` → all
    /// tiers) rather than yielding an empty set — an empty set would mean
    /// "collect nothing", and silently halting all collection is the worse
    /// failure mode.
    private static func tiers(from args: [String]) -> Set<CollectionTier>? {
        guard let idx = args.firstIndex(of: "--tiers"), idx + 1 < args.count else {
            return nil
        }
        var result: Set<CollectionTier> = []
        for token in args[idx + 1].split(separator: ",") {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let tier = CollectionTier(rawValue: trimmed) {
                result.insert(tier)
            } else {
                AppLogger.schedule.warning(
                    "LaunchAgentService.parse: unknown tier '\(trimmed, privacy: .public)' in --tiers; dropped"
                )
            }
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - Cadence / Next Run

    /// Convert a `StartCalendarInterval` value (dict or array of dicts) into a
    /// human-readable string for the table.
    private static func describeCadence(_ raw: Any?) -> String {
        let entries = calendarEntries(from: raw)
        if let first = entries.first {
            if entries.count == 5,
               Set(entries.compactMap { $0["Weekday"] }) == Set(1...5) {
                return "Weekdays \(formatTime(first))"
            }
            if entries.count > 1 {
                return "\(entries.count)× weekly · " + formatCalendar(first)
            }
            return formatCalendar(first)
        }
        return "manual"
    }

    private static func nextRunText(from raw: Any?, enabled: Bool) -> String {
        guard enabled, let next = nextRunDate(from: raw) else { return "—" }
        return FileDisplay.date(next)
    }

    private static func nextRunDate(from raw: Any?, now: Date = Date()) -> Date? {
        calendarEntries(from: raw)
            .compactMap { nextDate(for: $0, after: now) }
            .min()
    }

    /// How far back to search for the most recent past fire. A monthly schedule
    /// (Day-of-month entry) still resolves within this window; a malformed plist
    /// can't loop `nextDate` forward past `now` more than this many steps.
    private static let lastFireSearchWindowDays = 35

    /// The most recent time a `StartCalendarInterval` schedule SHOULD have fired
    /// at or before `now`, across all its entries — the past-looking counterpart
    /// of `nextRunDate`. Returns nil for a manual/empty/garbage interval.
    ///
    /// Implementation note: rather than `Calendar.nextDate(direction: .backward)`
    /// — whose `matchingPolicy` semantics differ subtly going backward — this
    /// steps the SAME forward `nextDate(for:after:)` used by `nextRunDate`
    /// (proven correct forward) from `now - window`, keeping the last fire that
    /// is still `<= now`. Identical matching logic, no backward edge cases. The
    /// `<=` (not `<`) means a fire exactly at `now` counts as "already fired".
    static func lastScheduledFireDate(from raw: Any?, before now: Date = Date()) -> Date? {
        let entries = calendarEntries(from: raw)
        guard !entries.isEmpty else { return nil }
        let windowStart = now.addingTimeInterval(
            -Double(lastFireSearchWindowDays) * 86_400
        )
        var latest: Date?
        // Cap the outer loop too: real schedules have a handful of calendar
        // entries (launchd itself struggles with large arrays), so 64 is far
        // beyond any legitimate plist while bounding attacker-chosen work.
        for entry in entries.prefix(64) {
            var cursor = windowStart
            // Cap iterations defensively so a pathological entry can't spin.
            for _ in 0..<(lastFireSearchWindowDays * 24 + 8) {
                guard let next = nextDate(for: entry, after: cursor),
                      next <= now else { break }
                if latest == nil || next > latest! { latest = next }
                cursor = next
            }
        }
        return latest
    }

    private static func nextDate(for entry: [String: Int], after now: Date) -> Date? {
        let cal = Calendar.current
        var components = DateComponents()
        components.hour = entry["Hour"] ?? 0
        components.minute = entry["Minute"] ?? 0
        components.second = 0
        if let weekday = entry["Weekday"] {
            components.weekday = calendarWeekday(fromLaunchdWeekday: weekday)
        }
        if let day = entry["Day"] {
            components.day = day
        }
        return cal.nextDate(
            after: now,
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }

    private static func calendarWeekday(fromLaunchdWeekday value: Int) -> Int {
        value == 0 || value == 7 ? 1 : value + 1
    }

    private static func calendarEntries(from raw: Any?) -> [[String: Int]] {
        if let dict = raw as? [String: Int] {
            return [dict]
        }
        if let dict = raw as? [String: Any] {
            return [intDictionary(from: dict)]
        }
        if let array = raw as? [[String: Int]] {
            return array
        }
        if let array = raw as? [[String: Any]] {
            return array.map(intDictionary)
        }
        return []
    }

    private static func intDictionary(from dict: [String: Any]) -> [String: Int] {
        dict.reduce(into: [:]) { result, item in
            if let value = item.value as? Int {
                result[item.key] = value
            } else if let value = item.value as? NSNumber {
                result[item.key] = value.intValue
            }
        }
    }

    private static func formatCalendar(_ d: [String: Int]) -> String {
        let timeStr = formatTime(d)
        if let weekday = d["Weekday"] {
            let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            let dayName = names[safe: weekday] ?? "Day\(weekday)"
            return "\(dayName) \(timeStr)"
        }
        if let day = d["Day"] {
            return "Day \(day) \(timeStr)"
        }
        return "Daily \(timeStr)"
    }

    private static func formatTime(_ d: [String: Int]) -> String {
        let h = d["Hour"] ?? 0
        let m = d["Minute"] ?? 0
        return String(format: "%02d:%02d", h, m)
    }

    private static func humanName(from slug: String, mode: Schedule.RunMode) -> String {
        if slug.isEmpty {
            switch mode {
            case .snapshotOnly: return "Snapshot"
            case .jamfCLIOnly: return "Jamf CLI Report"
            case .jamfCLIFull: return "Full Automation"
            case .csvAssisted: return "CSV Assisted"
            case .backup: return "Configuration Backup"
            }
        }
        return slug.replacingOccurrences(of: "-", with: " ").capitalized
    }

    // MARK: - Run Status

    private struct ParsedRunStatus {
        let finishedAt: Date?
        let success: Bool?
        /// The run's process exit code as recorded by `ScheduledRunRecorder`
        /// (`exit_code`). Carried so a failing row can name the CAUSE
        /// (auth / privileges / throttling) instead of only "reported failure".
        let exitCode: Int32?
        let artifacts: [String]
    }

    private struct ParsedLogSummary {
        let date: Date?
        let exitCode: Int32?
        let hasFailureMarker: Bool
        let hasPartialMarker: Bool
    }

    private static func statusFileURL(
        from args: [String],
        profile: String,
        label: String
    ) -> URL? {
        guard let root = WorkspacePathGuard.root(for: profile) else { return nil }
        let rawPath: String
        if let idx = args.firstIndex(of: "--status-file"), idx + 1 < args.count {
            rawPath = args[idx + 1]
        } else {
            rawPath = root
                .appendingPathComponent("automation", isDirectory: true)
                .appendingPathComponent("\(label)_status.json")
                .path
        }
        return validatedWorkspaceURL(rawPath, profile: profile)
    }

    private static func multiStatusFileURL(from args: [String], label: String) -> URL? {
        guard let idx = args.firstIndex(of: "--status-file"), idx + 1 < args.count else {
            return nil
        }
        return validatedMultiLogURL(args[idx + 1], label: label)
    }

    private static func readRunStatus(
        from url: URL?,
        profile: String
    ) -> ParsedRunStatus? {
        guard let root = WorkspacePathGuard.root(for: profile),
              let url,
              let safeURL = WorkspacePathGuard.validate(url, under: root),
              let values = try? safeURL.resourceValues(forKeys: [.fileSizeKey]),
              (values.fileSize ?? 0) <= 1_048_576,
              let data = try? Data(contentsOf: safeURL),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return ParsedRunStatus(
            finishedAt: dateValue(payload["finished_at"]),
            success: payload["success"] as? Bool,
            exitCode: exitCodeValue(payload["exit_code"]),
            artifacts: artifactLabels(from: payload, root: root)
        )
    }

    private static func readMultiRunStatus(from url: URL?, label: String) -> ParsedRunStatus? {
        guard let url,
              let safeURL = validatedMultiLogURL(url.path, label: label),
              let values = try? safeURL.resourceValues(forKeys: [.fileSizeKey]),
              (values.fileSize ?? 0) <= 1_048_576,
              let data = try? Data(contentsOf: safeURL),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return ParsedRunStatus(
            finishedAt: dateValue(payload["finished_at"]),
            success: payload["success"] as? Bool,
            exitCode: exitCodeValue(payload["exit_code"]),
            artifacts: []
        )
    }

    /// Fallback run status for a multi (all-profiles) agent whose plist has no
    /// `--status-file`: the managed scheduled run records status per profile at
    /// `<workspace>/automation/<label>_status.json`. Scan every local profile
    /// for that label and return the record with the newest `finishedAt`.
    private static func newestMultiRunStatus(label: String) -> ParsedRunStatus? {
        var best: ParsedRunStatus?
        for profile in ProfileService.discoverLocal().map(\.name) {
            let url = statusFileURL(from: [], profile: profile, label: label)
            guard let status = readRunStatus(from: url, profile: profile),
                  let finished = status.finishedAt else { continue }
            if let bestFinished = best?.finishedAt, finished <= bestFinished { continue }
            best = status
        }
        return best
    }

    private static func readLogSummary(
        from plist: [String: Any],
        profile: String,
        label: String,
        isMulti: Bool
    ) -> ParsedLogSummary {
        let urls = ["StandardOutPath", "StandardErrorPath"]
            .compactMap { plist[$0] as? String }
            .compactMap {
                isMulti
                    ? validatedMultiLogURL($0, label: label)
                    : validatedWorkspaceURL($0, profile: profile)
            }
            .filter { fileSize($0) > 0 }

        let newestDate = urls
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate }
            .max()

        var exitCode: Int32?
        var hasFailureMarker = false
        var hasPartialMarker = false

        let summaryBasedPartial = urls.first
            .map { checkSummaryFileForPartialStatus(logURL: $0, profile: profile, isMulti: isMulti) }
            ?? false

        for url in urls {
            let tail = parseLogTail(from: url)
            if exitCode == nil {
                exitCode = tail.exitCode
            }
            hasFailureMarker = hasFailureMarker || tail.hasFailureMarker
            hasPartialMarker = hasPartialMarker || tail.hasPartialMarker
        }
        return ParsedLogSummary(
            date: newestDate,
            exitCode: exitCode,
            hasFailureMarker: hasFailureMarker,
            hasPartialMarker: summaryBasedPartial || hasPartialMarker
        )
    }

    private static func lastStatus(
        from runStatus: ParsedRunStatus?,
        logSummary: ParsedLogSummary
    ) -> Schedule.LastStatus {
        if let success = runStatus?.success {
            return success ? .ok : .fail
        }
        if let exitCode = logSummary.exitCode {
            if exitCode == 0 && logSummary.hasPartialMarker {
                return .partial
            }
            return exitCode == 0 ? .ok : .fail
        }
        return logSummary.hasFailureMarker ? .fail : .ok
    }

    /// PR-11 / threat-model T-12: per-LaunchAgent-run summary files
    /// (`summary_<logFilename>.json`) are now produced by the Python
    /// `_emit_per_log_summary_json` helper, called from `cmd_generate` when
    /// `per_log_summary_filename` is passed. Returns false for multi-profile
    /// logs (no per-run summary in that layout).
    ///
    /// **Manifest discipline:** before trusting the `status` field, verify
    /// the file's SHA-256 against its sibling `manifest.json`. On
    /// `.mismatch` or `.corrupt`, return false (defer to caller's
    /// log-marker fallback in `lastStatus`) rather than trusting an
    /// attacker-modifiable file. On `.absent` / `.omitted` / `.verified`,
    /// trust the file content as before.
    private static func checkSummaryFileForPartialStatus(
        logURL: URL,
        profile: String,
        isMulti: Bool
    ) -> Bool {
        guard !isMulti else { return false }
        guard let root = WorkspacePathGuard.root(for: profile) else { return false }
        let logFilename = logURL.deletingPathExtension().lastPathComponent
        let summaryURL = root
            .appendingPathComponent("snapshots")
            .appendingPathComponent("computers")
            .appendingPathComponent("summaries")
            .appendingPathComponent("summary_\(logFilename).json")
        if FileManager.default.fileExists(atPath: summaryURL.path),
           let data = try? Data(contentsOf: summaryURL) {
            let verification = SnapshotManifest.verify(snapshot: summaryURL, data: data)
            // Trust only `.verified` or `.absent` (legacy pre-PR-11).
            // `.mismatch`, `.corrupt`, and `.omitted` all signal an
            // attacker-modifiable summary (security-reviewer 2nd pass
            // M-01: `.omitted` is an injection bypass — every legitimate
            // PR-11 write registers the file in the manifest). Caller's
            // `lastStatus` performs the log-marker fallback.
            if verification == .verified || verification == .absent {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let status = json["status"] as? String {
                    return status == "partial"
                }
            }
        }
        return false
    }

    private static func artifactLabels(
        from payload: [String: Any],
        root: URL
    ) -> [String] {
        var labels: [String] = []
        var seen: Set<String> = []
        addArtifact("xlsx_report_path", as: "XLSX", from: payload, root: root, labels: &labels, seen: &seen)
        addArtifact("html_report_path", as: "HTML", from: payload, root: root, labels: &labels, seen: &seen)
        addArtifact("inventory_csv_path", as: "CSV", from: payload, root: root, labels: &labels, seen: &seen)
        if labels.isEmpty {
            addReportArtifact(from: payload["report_path"], root: root, labels: &labels, seen: &seen)
        }
        if let exported = payload["exported_reports"] as? [String],
           exported.contains(where: { artifactExists($0, root: root) }) {
            appendUnique("EXPORTS", labels: &labels, seen: &seen)
        }
        return labels
    }

    private static func addArtifact(
        _ key: String,
        as label: String,
        from payload: [String: Any],
        root: URL,
        labels: inout [String],
        seen: inout Set<String>
    ) {
        guard let raw = payload[key] as? String, artifactExists(raw, root: root) else { return }
        appendUnique(label, labels: &labels, seen: &seen)
    }

    private static func addReportArtifact(
        from raw: Any?,
        root: URL,
        labels: inout [String],
        seen: inout Set<String>
    ) {
        guard let path = raw as? String,
              artifactExists(path, root: root) else { return }
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "xlsx": appendUnique("XLSX", labels: &labels, seen: &seen)
        case "html": appendUnique("HTML", labels: &labels, seen: &seen)
        case "csv": appendUnique("CSV", labels: &labels, seen: &seen)
        default: appendUnique("OUTPUT", labels: &labels, seen: &seen)
        }
    }

    private static func appendUnique(
        _ label: String,
        labels: inout [String],
        seen: inout Set<String>
    ) {
        guard seen.insert(label).inserted else { return }
        labels.append(label)
    }

    private static func artifactExists(_ rawPath: String, root: URL) -> Bool {
        let url = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath)
        guard let safeURL = WorkspacePathGuard.validate(url, under: root) else { return false }
        return FileManager.default.fileExists(atPath: safeURL.path)
    }

    /// Decode the run-status JSON's `exit_code` defensively.
    ///
    /// A missing, boolean, or non-numeric value yields nil — NEVER 0, which
    /// would read as "succeeded" and misreport the cause of a failure. JSON
    /// booleans bridge to `NSNumber` too, so they're rejected by CoreFoundation
    /// type id rather than by an `as? Bool` cast (which also matches 0/1
    /// numbers and would swallow the real `exit 1`).
    ///
    /// Internal (not private) purely so `AutomationHealthTests` can pin the
    /// missing/garbage-yields-nil contract without a real workspace on disk.
    static func exitCodeValue(_ raw: Any?) -> Int32? {
        guard let raw else { return nil }
        if let number = raw as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            // NaN/infinity have no meaningful `int64Value`; reject before
            // narrowing so a malformed record can't yield a plausible code.
            guard number.doubleValue.isFinite else { return nil }
            let value = number.int64Value
            guard value >= Int64(Int32.min), value <= Int64(Int32.max) else { return nil }
            return Int32(value)
        }
        if let text = raw as? String {
            return Int32(text.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func dateValue(_ raw: Any?) -> Date? {
        guard let text = raw as? String, !text.isEmpty else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: text) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: text)
    }

    static func parseLogTail(
        from url: URL
    ) -> (exitCode: Int32?, hasFailureMarker: Bool, hasPartialMarker: Bool) {
        guard let fh = FileHandle(forReadingAtPath: url.path) else { return (nil, false, false) }
        defer { fh.closeFile() }

        let fileSize = fh.seekToEndOfFile()
        let readSize = min(fileSize, 2_048)
        fh.seek(toFileOffset: fileSize - readSize)
        let data = fh.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return (nil, false, false) }

        var hasFailureMarker = false
        var hasPartialMarker = false
        var parsedExitCode: Int32? = nil
        for line in text.components(separatedBy: "\n").reversed() {
            let lower = line.lowercased()
            hasFailureMarker = hasFailureMarker
                || lower.contains("[fatal]")
                || lower.contains("[error]")
                || lower.contains("[fail]")
                || lower.contains("error:")
                || lower.contains("traceback")
            hasPartialMarker = hasPartialMarker || lower.contains("[partial]")
            if parsedExitCode == nil {
                parsedExitCode = exitCode(from: line)
            }
        }
        return (parsedExitCode, hasFailureMarker, hasPartialMarker)
    }

    static func exitCode(from line: String) -> Int32? {
        guard let range = line.range(
            of: #"exit\s+(-?\d+)"#,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return nil
        }
        let match = String(line[range])
        guard let codeRange = match.range(of: #"-?\d+"#, options: .regularExpression),
              let value = Int32(match[codeRange]) else {
            return nil
        }
        return value
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private static func validatedWorkspaceURL(_ rawPath: String, profile: String) -> URL? {
        guard let root = WorkspacePathGuard.root(for: profile) else { return nil }
        let expanded = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        return WorkspacePathGuard.validate(url, under: root)
    }

    private static func validatedMultiLogURL(_ rawPath: String, label: String) -> URL? {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/JamfReports/\(label)", isDirectory: true)
            .resolvingSymlinksInPath()
        let resolved = url.resolvingSymlinksInPath()
        let safePath = logDir.path
        let safePrefix = safePath + "/"
        guard resolved.path == safePath || resolved.path.hasPrefix(safePrefix) else { return nil }
        return resolved
    }

    private static func bootout(_ label: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
