import Foundation
import Darwin

/// LaunchAgent label, command helpers, and native plist writer for JamfReports automation.
///
/// Single-profile schedules use `nativeSingleWrite`; multi-profile schedules use
/// `nativeMultiWrite`. Both serialize the plist in Swift and invoke the app binary directly
/// with `--scheduled-run` — no Python or external CLI required.
enum LaunchAgentWriter {

    static let labelPrefix = "com.github.tonyyo11.jamf-reports-community"
    static let legacyLabelPrefix = "com.tonyyo.jrc"

    enum WriterError: Error, LocalizedError {
        case invalidProfile(String)
        case invalidSlug(String)
        case cadenceParseError(String)
        case outsideSafeDir(URL)

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let p):      "Profile '\(p)' contains invalid characters."
            case .invalidSlug(let s):          "Name produces invalid slug '\(s)' — use a-z, 0-9, hyphens."
            case .cadenceParseError(let s):    "Cannot parse cadence: \(s)"
            case .outsideSafeDir(let u):       "Path outside ~/Library/LaunchAgents: \(u.lastPathComponent)"
            }
        }
    }

    struct SetupPlan: Sendable {
        let label: String
        let arguments: [String]
        let plistURL: URL
    }

    // MARK: - Native single-profile LaunchAgent (Swift engine path)

    /// `--tiers <csv>` arguments for a schedule's plist, or `[]` when the
    /// schedule pins no tier set (PR-23 T-18).
    ///
    /// A `nil` `schedule.tiers` means "not specified" — the flag is omitted
    /// so `main.swift` applies its all-tiers default, preserving pre-PR-23
    /// plist behavior verbatim. The CSV uses sorted lowercase rawValues so
    /// the plist is byte-stable across writes (no spurious diffs, and a
    /// predictable layout for the trust check + parser).
    /// Environment for a scheduled run.
    ///
    /// A LaunchAgent starts the same binary as the GUI, so it resolves the
    /// workspace root the same way — but only if it can read the preference.
    /// Naming the root explicitly makes the plist self-describing and survives
    /// a preferences domain the agent cannot read. Omitted entirely for the
    /// default `~/Jamf-Reports`, so a normal install's plists are unchanged.
    private static func scheduledRunEnvironment() -> [String: String] {
        guard WorkspaceRootStore.isCustomised() else { return [:] }
        // Read the STORED preference, not the resolved root: when this runs from
        // the headless --scheduled-run self-heal, the process was launched by a
        // plist that already carries JRC_WORKSPACES_ROOT, and `current()` checks
        // the environment before the preference. Going through the resolved root
        // would re-embed the value we inherited, so a Mac that never opens the
        // GUI could never converge on a second root change.
        return [
            WorkspaceRootStore.environmentKey:
                WorkspaceRootStore.current(environment: [:]).path,
        ]
    }

    private static func tierArguments(for schedule: Schedule) -> [String] {
        guard let tiers = schedule.tiers, !tiers.isEmpty else { return [] }
        let csv = tiers.map(\.rawValue).sorted().joined(separator: ",")
        return ["--tiers", csv]
    }

    /// `--exclude-profiles <csv>` arguments for a multi-profile schedule, or
    /// `[]` when the schedule excludes nothing. Only valid profile slugs are
    /// emitted; the CSV is sorted for byte-stable plists. main.swift re-parses
    /// and re-validates the value, so this is a convenience, not a trust gate.
    private static func excludeArguments(for schedule: Schedule) -> [String] {
        let valid = (schedule.excludedProfiles ?? [])
            .filter(ProfileService.isValid)
            .sorted()
        guard !valid.isEmpty else { return [] }
        return ["--exclude-profiles", valid.joined(separator: ",")]
    }

    /// Write a LaunchAgent plist that invokes `JamfReports --scheduled-run --profile <slug>`
    /// directly.
    ///
    /// The plist calls the current executable with `--scheduled-run`, which runs
    /// `ReportEngine.collect` + `ReportEngine.generate` in-process and exits.
    /// Log files are written to `~/Library/Logs/JamfReports/<label>/`.
    static func nativeSingleWrite(
        for schedule: Schedule,
        load: Bool
    ) throws -> SetupPlan {
        guard ProfileService.isValid(schedule.profile) else {
            throw WriterError.invalidProfile(schedule.profile)
        }
        guard let agentLabel = label(for: schedule) else {
            throw WriterError.invalidSlug(sanitizedSlug(from: schedule.name))
        }

        let cadence = try setupCadence(from: schedule.schedule)

        // Use the running executable so the plist survives app updates atomically.
        guard let execURL = Bundle.main.executableURL else {
            throw WriterError.invalidProfile("cannot resolve executable path")
        }
        let execPath = execURL.path

        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/JamfReports/\(agentLabel)", isDirectory: true)
        // 0o700: log files may contain device serials, hostnames, usernames.
        try FileManager.default.createDirectory(
            at: logDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logDir.path)

        let plistContent: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [
                execPath, "--scheduled-run",
                "--profile", schedule.profile,
                "--mode", schedule.mode.rawValue,
                // --label names the per-run record (ScheduledRunRecorder) so
                // Run History attributes runs to this schedule.
                "--label", agentLabel,
            ] + tierArguments(for: schedule),
            "StandardOutPath": logDir.appendingPathComponent("stdout.log").path,
            "StandardErrorPath": logDir.appendingPathComponent("stderr.log").path,
            "StartCalendarInterval": cadence.startCalendarIntervals,
            // Collect modes run at login to catch up a run missed while the Mac
            // was asleep/logged-out (idempotent via ReportEngine.collect's
            // cadence guard); re-render/backup modes stay false. See
            // Schedule.RunMode.runsAtLoad.
            "RunAtLoad": schedule.mode.runsAtLoad,
            "Disabled": !load,
            "EnvironmentVariables": scheduledRunEnvironment(),
        ]

        let plistURL = LaunchAgentService.agentsDir.appendingPathComponent("\(agentLabel).plist")
        let safeDir = LaunchAgentService.agentsDir.resolvingSymlinksInPath()
        guard plistURL.resolvingSymlinksInPath().path.hasPrefix(safeDir.path + "/")
                || plistURL.resolvingSymlinksInPath().path == safeDir.path else {
            throw WriterError.outsideSafeDir(plistURL)
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plistContent, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        // 0600: plist embeds workspace paths and profile name.
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: plistURL.path
            )
        } catch {
            AppLogger.cli.warning(
                """
                nativeSingleWrite: chmod 0600 failed for \
                \(plistURL.lastPathComponent, privacy: .public): \
                \(error.localizedDescription, privacy: .private)
                """
            )
        }

        return SetupPlan(label: agentLabel, arguments: [], plistURL: plistURL)
    }

    // MARK: - Load / Unload / Delete

    /// Remove the agent: `launchctl bootout gui/<uid>/<label>`.
    static func unload(_ label: String) async -> Int32 {
        guard isValidLabel(label) else { return -1 }
        return await launchctl(["bootout", "gui/\(getuid())/\(label)"])
    }

    /// Execute the exact generated `launchagent-run` command for a schedule and
    /// append output to the same log files launchd uses for scheduled runs.
    static func runNow(
        _ label: String,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async -> Int32 {
        if isMultiLabel(label) {
            return await runMultiNow(label, onLine: onLine)
        }
        do {
            let plan = try manualRunPlan(for: label)
            return await runManualPlan(plan, onLine: onLine)
        } catch {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] \(error.localizedDescription)"))
            return -1
        }
    }

    private static func runMultiNow(
        _ label: String,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async -> Int32 {
        let plistURL = LaunchAgentService.agentsDir.appendingPathComponent("\(label).plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String], args.count > 1
        else {
            onLine(.init(
                timestamp: Date(),
                level: .fail,
                text: "[error] multi plist missing or malformed for \(label)"
            ))
            return -1
        }
        guard multiProgramArgumentsAreTrusted(args, label: label) else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] multi LaunchAgent command is not trusted"))
            return -1
        }

        let stdoutPath = plist["StandardOutPath"] as? String
        let stderrPath = plist["StandardErrorPath"] as? String
        let workingDir = plist["WorkingDirectory"] as? String

        guard let stdoutURL = validatedMultiLogURL(stdoutPath, label: label, filename: "stdout.log") else {
            onLine(.init(
                timestamp: Date(),
                level: .fail,
                text: "[error] multi LaunchAgent stdout path does not match the expected "
                    + "~/Library/Logs/JamfReports/\(label)/stdout.log — delete and re-save this schedule"
            ))
            return -1
        }
        guard let stderrURL = validatedMultiLogURL(stderrPath, label: label, filename: "stderr.log") else {
            onLine(.init(
                timestamp: Date(),
                level: .fail,
                text: "[error] multi LaunchAgent stderr path does not match the expected "
                    + "~/Library/Logs/JamfReports/\(label)/stderr.log — delete and re-save this schedule"
            ))
            return -1
        }
        guard isExpectedMultiWorkingDirectory(workingDir) else {
            onLine(.init(
                timestamp: Date(),
                level: .fail,
                text: "[error] multi LaunchAgent WorkingDirectory must be \(ProfileService.workspacesRoot().path)"
            ))
            return -1
        }

        let execPath = args[0]
        let effectiveWorkingDir = workingDir ?? ProfileService.workspacesRoot().path
        if workingDir == nil {
            onLine(.init(
                timestamp: Date(),
                level: .warn,
                text: "[warn] LaunchAgent WorkingDirectory key missing; defaulting to \(effectiveWorkingDir) "
                    + "— re-save this schedule to persist the key"
            ))
        }
        return await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: execPath)
            p.arguments = Array(args.dropFirst())
            p.currentDirectoryURL = URL(fileURLWithPath: effectiveWorkingDir)
            p.environment = launchEnvironment(from: plist)

            var outFile: FileHandle?
            var errFile: FileHandle?
            let outLock = NSLock()
            let errLock = NSLock()

            let multiLogDir = stdoutURL.deletingLastPathComponent()
            // 0o700: run logs contain device serials, hostnames, and usernames.
            do {
                try FileManager.default.createDirectory(
                    at: multiLogDir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: multiLogDir.path
                )
                outFile = try appendHandle(for: stdoutURL)
                errFile = try appendHandle(for: stderrURL)
            } catch {
                onLine(.init(
                    timestamp: Date(),
                    level: .warn,
                    text: "[warn] could not open run log files: \(error.localizedDescription)"
                        + " — output will not be persisted"
                ))
            }

            let started = Date()
            let header = "\n[info] manual multi-profile Run now started "
                + "\(ISO8601DateFormatter().string(from: started)) for \(label)\n"
            if let outFile = outFile { write(header, to: outFile, lock: outLock) }
            onLine(.init(
                timestamp: started,
                level: .info,
                text: header.trimmingCharacters(in: .whitespacesAndNewlines)
            ))

            let finalOutFile = outFile
            let finalErrFile = errFile

            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { fh in
                let data = fh.availableData
                guard !data.isEmpty else { return }
                if let outFile = finalOutFile { write(data, to: outFile, lock: outLock) }
                if let errFile = finalErrFile { write(data, to: errFile, lock: errLock) }

                let text = String(decoding: data, as: UTF8.self)
                for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                    onLine(.init(timestamp: Date(), level: .info, text: line))
                }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                
                let seconds = max(0, Int(Date().timeIntervalSince(started).rounded()))
                let footer = "[info] exit \(proc.terminationStatus) after \(seconds)s\n"
                if let outFile = finalOutFile { write(footer, to: outFile, lock: outLock) }
                onLine(.init(
                    timestamp: Date(),
                    level: proc.terminationStatus == 0 ? .ok : .fail,
                    text: footer.trimmingCharacters(in: .newlines)
                ))

                try? finalOutFile?.close()
                try? finalErrFile?.close()
                cont.resume(returning: proc.terminationStatus)
            }
            do {
                try p.run()
            } catch {
                let message = "[fatal] \(error.localizedDescription)\n"
                if let outFile = finalOutFile { write(message, to: outFile, lock: outLock) }
                if let errFile = finalErrFile { write(message, to: errFile, lock: errLock) }
                onLine(.init(timestamp: Date(), level: .fail, text: message.trimmingCharacters(in: .newlines)))
                
                try? finalOutFile?.close()
                try? finalErrFile?.close()
                cont.resume(returning: -1)
            }
        }
    }

    private static func multiProgramArgumentsAreTrusted(_ args: [String], label: String) -> Bool {
        guard let execPath = args.first,
              FileManager.default.isExecutableFile(atPath: execPath) else {
            return false
        }
        // Native format: [exec, "--scheduled-run", "--profile", slug,
        //                 "--mode", rawValue, "--tiers", csv, "--all-profiles"]
        // Pre-PR-20 plists omit --mode; pre-PR-23 plists omit --tiers. The
        // trust check stays permissive about trailing flags so legacy multi
        // plists still execute — it only pins the [1]/[2] prefix + a valid
        // profile slug at [3].
        if args.count >= 4, args[1] == "--scheduled-run", args[2] == "--profile" {
            guard ProfileService.isValid(args[3]) else { return false }
            return isTrustedNativeExecutable(URL(fileURLWithPath: execPath))
        }
        // Legacy jamf-cli multi format (read-only support for pre-existing plists).
        if args.count >= 2, args[1] == "multi" {
            return isTrustedJamfCLIExecutable(execPath)
                && legacyJamfCLIMultiArgumentsAreSafe(args)
        }
        return false
    }

    private static func legacyJamfCLIMultiArgumentsAreSafe(_ args: [String]) -> Bool {
        guard let separator = args.firstIndex(of: "--"),
              Array(args.dropFirst(separator + 1)) == ["pro", "collect"] else {
            return false
        }

        var i = 2
        while i < separator {
            switch args[i] {
            case "--sequential":
                break
            case "--profiles":
                guard i + 1 < separator, allProfilesAreValid(args[i + 1]) else { return false }
                i += 1
            case "--filter":
                guard i + 1 < separator, isSafeMultiProfileFilter(args[i + 1]) else { return false }
                i += 1
            default:
                return false
            }
            i += 1
        }
        return true
    }

    /// Delete a generated plist.
    static func delete(_ label: String) throws {
        guard isValidLabel(label) else {
            throw WriterError.outsideSafeDir(
                LaunchAgentService.agentsDir.appendingPathComponent("\(label).plist")
            )
        }
        let plistURL = LaunchAgentService.agentsDir.appendingPathComponent("\(label).plist")
        let safeDir = LaunchAgentService.agentsDir.resolvingSymlinksInPath()
        guard plistURL.resolvingSymlinksInPath().path.hasPrefix(safeDir.path + "/") else {
            throw WriterError.outsideSafeDir(plistURL)
        }
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        try FileManager.default.removeItem(at: plistURL)
    }

    // MARK: - Label helper

    static func label(for schedule: Schedule) -> String? {
        if let existing = schedule.launchAgentLabel, isValidLabel(existing) {
            return existing
        }
        let slug = sanitizedSlug(from: schedule.name)
        guard isValidComponent(slug) else { return nil }
        if schedule.isMulti {
            let candidate = "\(labelPrefix).multi.\(slug)"
            return isValidLabel(candidate) ? candidate : nil
        }
        guard ProfileService.isValid(schedule.profile) else { return nil }
        let candidate = "\(labelPrefix).\(schedule.profile).\(slug)"
        return isValidLabel(candidate) ? candidate : nil
    }

    // MARK: - Multi-profile LaunchAgent (native)

    /// Write a LaunchAgent plist for a multi-profile schedule.
    ///
    /// The plist invokes the current app binary with `--scheduled-run --profile <p>
    /// --all-profiles` so the app's native engine fans out across all initialized profiles.
    static func nativeMultiWrite(
        for schedule: Schedule,
        executableURL: URL,
        load: Bool
    ) throws -> SetupPlan {
        guard ProfileService.isValid(schedule.profile) else {
            throw WriterError.invalidProfile(schedule.profile)
        }
        guard let agentLabel = label(for: schedule) else {
            throw WriterError.invalidSlug(sanitizedSlug(from: schedule.name))
        }

        let cadence = try setupCadence(from: schedule.schedule)
        let execPath = executableURL.path

        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/JamfReports/\(agentLabel)", isDirectory: true)
        // 0o700: log files contain device serials, hostnames, and usernames.
        try FileManager.default.createDirectory(
            at: logDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logDir.path)

        let plistContent: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [
                execPath,
                "--scheduled-run",
                "--profile", schedule.profile,
                "--mode", schedule.mode.rawValue,
                // --label names the per-run record (ScheduledRunRecorder) so
                // Run History attributes runs to this schedule.
                "--label", agentLabel,
            ] + tierArguments(for: schedule) + [
                "--all-profiles",
            ] + excludeArguments(for: schedule),
            "WorkingDirectory": ProfileService.workspacesRoot().path,
            "StandardOutPath": logDir.appendingPathComponent("stdout.log").path,
            "StandardErrorPath": logDir.appendingPathComponent("stderr.log").path,
            "StartCalendarInterval": cadence.startCalendarIntervals,
            // Collect modes run at login to catch up a run missed while the Mac
            // was asleep/logged-out (idempotent via ReportEngine.collect's
            // cadence guard); re-render/backup modes stay false. See
            // Schedule.RunMode.runsAtLoad.
            "RunAtLoad": schedule.mode.runsAtLoad,
            "Disabled": !load,
            "EnvironmentVariables": scheduledRunEnvironment(),
        ]

        let plistURL = LaunchAgentService.agentsDir.appendingPathComponent("\(agentLabel).plist")
        let safeDir = LaunchAgentService.agentsDir.resolvingSymlinksInPath()
        guard plistURL.resolvingSymlinksInPath().path.hasPrefix(safeDir.path + "/")
                || plistURL.resolvingSymlinksInPath().path == safeDir.path else {
            throw WriterError.outsideSafeDir(plistURL)
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plistContent, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: plistURL.path
            )
        } catch {
            AppLogger.cli.warning(
                """
                nativeMultiWrite: chmod 0600 failed for \
                \(plistURL.lastPathComponent, privacy: .public): \
                \(error.localizedDescription, privacy: .private)
                """
            )
        }

        return SetupPlan(label: agentLabel, arguments: [], plistURL: plistURL)
    }

    static func loadPlist(at url: URL) async -> Int32 {
        await launchctl(["bootstrap", "gui/\(getuid())", url.path])
    }

    static func isMultiLabel(_ label: String) -> Bool {
        label.hasPrefix("\(labelPrefix).multi.")
    }

    // MARK: - Private helpers

    private struct CadenceOptions {
        let schedule: String
        let timeOfDay: String
        let weekday: String?
        let dayOfMonth: Int?

        var startCalendarIntervals: [[String: Int]] {
            let parts = timeOfDay.split(separator: ":").compactMap { Int($0) }
            let hour = parts.count > 0 ? parts[0] : 6
            let minute = parts.count > 1 ? parts[1] : 0
            let wdMap = ["sunday":0,"monday":1,"tuesday":2,"wednesday":3,"thursday":4,"friday":5,"saturday":6]
            switch schedule {
            case "weekly":
                let wd = wdMap[weekday?.lowercased() ?? ""] ?? 1
                return [["Weekday": wd, "Hour": hour, "Minute": minute]]
            case "weekdays":
                return (1...5).map { ["Weekday": $0, "Hour": hour, "Minute": minute] }
            case "monthly":
                return [["Day": dayOfMonth ?? 1, "Hour": hour, "Minute": minute]]
            default:
                return [["Hour": hour, "Minute": minute]]
            }
        }
    }

    private struct ManualRunPlan {
        let label: String
        let executable: URL
        let arguments: [String]
        let workingDirectory: URL
        let environment: [String: String]
        let stdoutURL: URL
        let stderrURL: URL
    }

    private enum ManualRunError: Error, LocalizedError {
        case invalidLabel(String)
        case missingPlist(String)
        case malformedPlist(String)
        case unsupportedCommand(String)
        case unsafePath(String)
        case notExecutable(String)
        case untrustedExecutable(String)
        case untrustedScript(String)

        var errorDescription: String? {
            switch self {
            case .invalidLabel(let label):      "Invalid LaunchAgent label: \(label)"
            case .missingPlist(let label):      "LaunchAgent plist not found for \(label)"
            case .malformedPlist(let detail):   "LaunchAgent plist is malformed: \(detail)"
            case .unsupportedCommand(let label): "LaunchAgent \(label) is not a generated scheduled-run command."
            case .unsafePath(let path):         "LaunchAgent path is outside the profile workspace: \(path)"
            case .notExecutable(let path):      "LaunchAgent executable is not runnable: \(path)"
            case .untrustedExecutable(let path): "LaunchAgent executable is not the trusted app binary: \(path)"
            case .untrustedScript(let path):    "LaunchAgent script is not trusted: \(path)"
            }
        }
    }

    /// True when ``path`` is the same `jamf-cli` executable the app would
    /// resolve AND that executable passes the M-01 codesign gate.
    ///
    /// Path-identity alone is insufficient: a tampered binary placed at the
    /// expected location would satisfy ``sameResolvedPath`` but must still be
    /// refused. The codesign gate (mirrored from ``CLIBridge.run``) closes the
    /// 4th spawn-site identified in the M-01 review (legacy multi
    /// ``jamf-cli`` launchctl path via ``runMultiNow``).
    ///
    /// The ``_testLocatedOverride`` parameter is a test seam, NOT a production
    /// API: pass nil (default) in production code. Tests pass a fake binary
    /// URL so the codesign gate is reachable even when the located
    /// ``jamf-cli`` is absent or signed. The leading underscore signals "do
    /// not pass from production callers."
    static func isTrustedJamfCLIExecutable(
        _ path: String,
        _testLocatedOverride: URL? = nil
    ) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        let candidate = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL
        guard candidate.lastPathComponent == "jamf-cli",
              FileManager.default.isExecutableFile(atPath: candidate.path),
              let located = _testLocatedOverride ?? ExecutableLocator.locate("jamf-cli"),
              sameResolvedPath(candidate, located) else {
            return false
        }
        // M-01 fourth-site closure: refuse to launch even a path-identity-
        // matching jamf-cli that fails signature verification. Returns nil
        // when the gate accepts; non-nil (sentinel -1) on rejection.
        return CLIBridge.codesignGate(executable: candidate, onLine: CLIBridge.noOpOnLine) == nil
    }

    private static func setupCadence(from raw: String) throws -> CadenceOptions {
        let normalized = raw
            .replacingOccurrences(of: " · ", with: " ")
            .replacingOccurrences(of: "\u{00B7}", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let tokens = normalized.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard tokens.count >= 2, let lastToken = tokens.last else {
            throw WriterError.cadenceParseError(raw)
        }

        let timeOfDay = try parseHHMM(lastToken, raw: raw)
        let key = tokens[0].lowercased()

        if key == "daily" {
            return .init(schedule: "daily", timeOfDay: timeOfDay, weekday: nil, dayOfMonth: nil)
        }
        if key == "weekdays" {
            return .init(schedule: "weekdays", timeOfDay: timeOfDay, weekday: nil, dayOfMonth: nil)
        }
        if key == "day", tokens.count >= 3, let day = Int(tokens[1]), (1...28).contains(day) {
            return .init(schedule: "monthly", timeOfDay: timeOfDay, weekday: nil, dayOfMonth: day)
        }
        if let day = parseOrdinal(key), (1...28).contains(day) {
            return .init(schedule: "monthly", timeOfDay: timeOfDay, weekday: nil, dayOfMonth: day)
        }
        if let weekday = normalizedWeekday(key) {
            return .init(schedule: "weekly", timeOfDay: timeOfDay, weekday: weekday, dayOfMonth: nil)
        }
        throw WriterError.cadenceParseError(raw)
    }

    private static func launchctl(_ args: [String]) async -> Int32 {
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
                    "launchctl \(args.first ?? "", privacy: .public) launch failed: \(error.localizedDescription, privacy: .private)"
                )
                cont.resume(returning: -1)
            }
        }
    }

    private static func manualRunPlan(for label: String) throws -> ManualRunPlan {
        guard isValidLabel(label) else { throw ManualRunError.invalidLabel(label) }
        guard let profile = profileName(from: label),
              let root = WorkspacePathGuard.root(for: profile) else {
            throw ManualRunError.malformedPlist("cannot determine profile from label")
        }

        let plistURL = LaunchAgentService.agentsDir.appendingPathComponent("\(label).plist")
        let safeAgentsDir = LaunchAgentService.agentsDir.resolvingSymlinksInPath()
        guard plistURL.resolvingSymlinksInPath().path.hasPrefix(safeAgentsDir.path + "/") else {
            throw ManualRunError.unsafePath(plistURL.path)
        }
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            throw ManualRunError.missingPlist(label)
        }

        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization
                .propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String],
              args.count >= 3 else {
            throw ManualRunError.malformedPlist("missing ProgramArguments")
        }

        // Native format: [exec, "--scheduled-run", "--profile", slug,
        //                 "--mode", rawValue, "--tiers", csv]
        // Produced by nativeSingleWrite / nativeMultiWrite. Pre-PR-20 plists
        // omit --mode; pre-PR-23 plists omit --tiers. main.swift falls back
        // to jamf-cli-only / all-tiers respectively when absent.
        guard args.count >= 4, args[1] == "--scheduled-run", args[2] == "--profile" else {
            throw ManualRunError.unsupportedCommand(label)
        }
        return try nativeManualRunPlan(
            label: label,
            plist: plist,
            args: args,
            profile: profile,
            root: root
        )
    }

    /// Validate and build a `ManualRunPlan` for the native plist format written by
    /// `nativeSingleWrite`. `ProgramArguments` is `[exec, "--scheduled-run", "--profile", slug]`.
    private static func nativeManualRunPlan(
        label: String,
        plist: [String: Any],
        args: [String],
        profile: String,
        root: URL
    ) throws -> ManualRunPlan {
        let plistProfile = args[3]
        guard ProfileService.isValid(plistProfile), plistProfile == profile else {
            throw ManualRunError.malformedPlist("profile in plist does not match label")
        }

        let executable = URL(fileURLWithPath: args[0])
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ManualRunError.notExecutable(executable.path)
        }
        // The native executable must be the app binary or a known macOS app bundle path.
        guard isTrustedNativeExecutable(executable) else {
            throw ManualRunError.untrustedExecutable(executable.path)
        }

        // Log paths are in ~/Library/Logs/JamfReports/<label>/. Build the
        // expected URLs directly via the helper — passing filename: "" plus
        // deletingLastPathComponent() strips the label folder and points at
        // the parent directory, which never matches what the writer emits.
        let expectedStdout = expectedMultiLogURL(label: label, filename: "stdout.log")
        let expectedStderr = expectedMultiLogURL(label: label, filename: "stderr.log")

        guard let rawStdout = plist["StandardOutPath"] as? String,
              let stdoutURL = expandedFileURL(rawStdout),
              sameResolvedPath(stdoutURL, expectedStdout) else {
            throw ManualRunError.unsafePath("stdout log")
        }
        guard let rawStderr = plist["StandardErrorPath"] as? String,
              let stderrURL = expandedFileURL(rawStderr),
              sameResolvedPath(stderrURL, expectedStderr) else {
            throw ManualRunError.unsafePath("stderr log")
        }

        return ManualRunPlan(
            label: label,
            executable: executable,
            arguments: Array(args.dropFirst()),
            workingDirectory: root,
            environment: CLIBridge.environmentForJamfCLI(),
            stdoutURL: stdoutURL,
            stderrURL: stderrURL
        )
    }

#if DEBUG
    /// Test seam (Epic #102, item #4): runs `nativeManualRunPlan` and returns
    /// its parsed result as public-typed fields, without promoting the private
    /// `ManualRunPlan` struct. `nativeManualRunPlan` is the path-validation core
    /// of the "Run now" flow — a regression there once silently broke it with no
    /// test to catch it. Compiled only into DEBUG builds.
    static func nativeManualRunPlanFieldsForTesting(
        label: String,
        plist: [String: Any],
        args: [String],
        profile: String,
        root: URL
    ) throws -> (executable: URL, arguments: [String], workingDirectory: URL,
                 stdoutURL: URL, stderrURL: URL) {
        let plan = try nativeManualRunPlan(
            label: label, plist: plist, args: args, profile: profile, root: root
        )
        return (plan.executable, plan.arguments, plan.workingDirectory,
                plan.stdoutURL, plan.stderrURL)
    }
#endif

    /// True only when the URL resolves to the current process's own executable.
    /// Restricting to Bundle.main prevents a tampered plist from pointing at any
    /// other binary under /Applications or ~/Applications.
    private static func isTrustedNativeExecutable(_ url: URL) -> Bool {
        guard let mainExecutable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return false
        }
        return url.resolvingSymlinksInPath().standardizedFileURL.path
            == mainExecutable.standardizedFileURL.path
    }

    private static func runManualPlan(
        _ plan: ManualRunPlan,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async -> Int32 {
        await Task.detached(priority: .userInitiated) {
            do {
                let stdoutLogDir = plan.stdoutURL.deletingLastPathComponent()
                let stderrLogDir = plan.stderrURL.deletingLastPathComponent()
                // 0o700: run logs contain device serials, hostnames, and usernames.
                try FileManager.default.createDirectory(
                    at: stdoutLogDir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: stdoutLogDir.path
                )
                try FileManager.default.createDirectory(
                    at: stderrLogDir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: stderrLogDir.path
                )

                let outFile = try appendHandle(for: plan.stdoutURL)
                let errFile = try appendHandle(for: plan.stderrURL)
                defer {
                    try? outFile.close()
                    try? errFile.close()
                }

                let process = Process()
                process.executableURL = plan.executable
                process.arguments = plan.arguments
                process.currentDirectoryURL = plan.workingDirectory
                process.environment = plan.environment

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                let outLock = NSLock()
                let errLock = NSLock()
                let started = Date()
                let header = "\n[info] manual Run now started "
                    + "\(ISO8601DateFormatter().string(from: started)) for \(plan.label)\n"
                write(header, to: outFile, lock: outLock)
                onLine(.init(timestamp: started, level: .info, text: header.trimmingCharacters(in: .whitespacesAndNewlines)))

                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    write(data, to: outFile, lock: outLock)
                    emit(data, stderr: false, onLine: onLine)
                }
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    write(data, to: errFile, lock: errLock)
                    emit(data, stderr: true, onLine: onLine)
                }

                do {
                    try process.run()
                } catch {
                    let message = "[fatal] \(error.localizedDescription)\n"
                    write(message, to: outFile, lock: outLock)
                    write(message, to: errFile, lock: errLock)
                    onLine(.init(timestamp: Date(), level: .fail, text: message.trimmingCharacters(in: .newlines)))
                    return -1
                }

                process.waitUntilExit()
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil

                let seconds = max(0, Int(Date().timeIntervalSince(started).rounded()))
                let footer = "[info] exit \(process.terminationStatus) after \(seconds)s\n"
                write(footer, to: outFile, lock: outLock)
                onLine(.init(timestamp: Date(), level: process.terminationStatus == 0 ? .ok : .fail, text: footer.trimmingCharacters(in: .newlines)))
                return process.terminationStatus
            } catch {
                onLine(.init(
                    timestamp: Date(),
                    level: .fail,
                    text: "[error] \(error.localizedDescription)"
                ))
                return -1
            }
        }.value
    }

    private static func profileName(from label: String) -> String? {
        let prefix = "\(labelPrefix)."
        guard label.hasPrefix(prefix) else { return nil }
        let tail = String(label.dropFirst(prefix.count))
        guard let first = tail.components(separatedBy: ".").first,
              ProfileService.isValid(first) else { return nil }
        return first
    }

    private static func argumentPath(_ flag: String, in args: [String], root: URL) -> URL? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return validatedWorkspaceURL(args[idx + 1], root: root)
    }

    private static func argumentValue(_ flag: String, in args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    private static func validatedWorkspaceURL(_ raw: String?, root: URL) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        return WorkspacePathGuard.validate(URL(fileURLWithPath: expanded), under: root)
    }

    static func isExpectedConfigURL(_ url: URL, root: URL) -> Bool {
        sameResolvedPath(url, root.appendingPathComponent("config.yaml"))
    }

    static func expectedStatusURL(label: String, root: URL) -> URL {
        root
            .appendingPathComponent("automation", isDirectory: true)
            .appendingPathComponent("\(filenameComponent(label))_status.json")
    }

    static func isExpectedStatusURL(_ url: URL, label: String, root: URL) -> Bool {
        sameResolvedPath(url, expectedStatusURL(label: label, root: root))
    }

    static func expectedStdoutURL(label: String, root: URL) -> URL {
        root
            .appendingPathComponent("automation", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("\(filenameComponent(label)).out.log")
    }

    static func expectedStderrURL(label: String, root: URL) -> URL {
        root
            .appendingPathComponent("automation", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("\(filenameComponent(label)).err.log")
    }

    static func isExpectedStdoutURL(_ url: URL, label: String, root: URL) -> Bool {
        sameResolvedPath(url, expectedStdoutURL(label: label, root: root))
    }

    static func isExpectedStderrURL(_ url: URL, label: String, root: URL) -> Bool {
        sameResolvedPath(url, expectedStderrURL(label: label, root: root))
    }

    static func expectedMultiLogURL(label: String, filename: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/JamfReports", isDirectory: true)
            .appendingPathComponent(label, isDirectory: true)
            .appendingPathComponent(filename)
    }

    static func isExpectedMultiLogURL(_ url: URL, label: String, filename: String) -> Bool {
        guard isValidLabel(label), isMultiLabel(label) else { return false }
        let expected = expectedMultiLogURL(label: label, filename: filename)
        let normalized = url.standardizedFileURL.path
        guard normalized == expected.standardizedFileURL.path else { return false }
        let logDir = expected.deletingLastPathComponent()
        let reportLogsDir = logDir.deletingLastPathComponent()
        return !isSymlink(url) && !isSymlink(logDir) && !isSymlink(reportLogsDir)
    }

    private static func validatedMultiLogURL(
        _ raw: String?,
        label: String,
        filename: String
    ) -> URL? {
        guard let raw, let url = expandedFileURL(raw),
              isExpectedMultiLogURL(url, label: label, filename: filename) else {
            return nil
        }
        return url
    }

    /// A missing `WorkingDirectory` key is accepted — the caller will fall back to
    /// `ProfileService.workspacesRoot()`. If the key is present, it must resolve to that root.
    static func isExpectedMultiWorkingDirectory(_ raw: String?) -> Bool {
        guard let raw else { return true }
        guard let url = expandedFileURL(raw) else { return false }
        return sameResolvedPath(url, ProfileService.workspacesRoot())
    }

    /// Swift twin of Python's `_filename_component` for generated status/log paths.
    static func filenameComponent(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        var output = ""
        var previousUnderscore = false
        for scalar in text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            if allowed.contains(scalar) {
                output.append(String(scalar))
                previousUnderscore = false
            } else if !previousUnderscore {
                output.append("_")
                previousUnderscore = true
            }
        }
        let trimmed = output.trimmingCharacters(in: CharacterSet(charactersIn: "._"))
        return trimmed.isEmpty ? "jamf_report" : trimmed
    }

    private static func sameResolvedPath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path
            == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func expandedFileURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    /// True when `url` is itself a symlink. Uses `attributesOfItem` (lstat — never
    /// follows) so it is reliable on a freshly constructed URL.
    /// `URL.resourceValues(.isSymbolicLinkKey)` follows the link on a fresh URL,
    /// which is the same bug already fixed in `DiagnosticBundleService.isSymlink`.
    private static func isSymlink(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private static func isPath(_ path: String, inside root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private static func allProfilesAreValid(_ raw: String) -> Bool {
        let profiles = raw
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        return !profiles.isEmpty && profiles.allSatisfy(ProfileService.isValid)
    }

    private static func isSafeMultiProfileFilter(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128, !trimmed.contains("\0") else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-*?[]")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static let safeLaunchPath = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ].joined(separator: ":")

    static func launchEnvironment(from plist: [String: Any]) -> [String: String] {
        let raw = plist["EnvironmentVariables"] as? [String: Any] ?? [:]
        var env: [String: String] = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": safeLaunchPath,
        ]
        if let xdgConfigHome = safeXDGConfigHome(raw["XDG_CONFIG_HOME"]) {
            env["XDG_CONFIG_HOME"] = xdgConfigHome
        }
        return env
    }

    private static func safeXDGConfigHome(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }

        let home = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let candidate = URL(fileURLWithPath: expanded)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        guard isPath(candidate, inside: home) else { return nil }
        return candidate
    }

    private static func appendHandle(for url: URL) throws -> FileHandle {
        // Create new run-log files at 0600 atomically — `createFile` without
        // attributes applies the process umask (typically 0022 → 0644 files),
        // leaking device serials/usernames/hostnames to anything that can read
        // the parent dir. The post Wave 1+2 silent-failure audit caught this
        // helper bypassing the 0600-on-create contract that AppLogger and
        // OnboardingFlow already enforce.
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
            )
        }
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        return handle
    }

    private static func write(_ text: String, to handle: FileHandle, lock: NSLock) {
        guard let data = text.data(using: .utf8) else { return }
        write(data, to: handle, lock: lock)
    }

    private static func write(_ data: Data, to handle: FileHandle, lock: NSLock) {
        lock.lock()
        defer { lock.unlock() }
        // Throwing variant: write(_:) raises an uncatchable ObjC exception when
        // the underlying write fails, which is reachable once the workspace
        // lives on a sync provider. A dropped progress line is acceptable; an
        // aborted process is not.
        try? handle.write(contentsOf: data)
    }

    private static func emit(
        _ data: Data,
        stderr: Bool,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
            let classified = CLIBridge.LogLevel.from(line: String(line))
            let level: CLIBridge.LogLevel = stderr && classified == .info ? .warn : classified
            onLine(.init(timestamp: Date(), level: level, text: String(line)))
        }
    }

    private static func parseHHMM(_ s: String, raw: String) throws -> String {
        let p = s.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]),
              (0...23).contains(h), (0...59).contains(m) else {
            throw WriterError.cadenceParseError(raw)
        }
        return String(format: "%02d:%02d", h, m)
    }

    private static func parseOrdinal(_ s: String) -> Int? {
        for suffix in ["st", "nd", "rd", "th"] {
            if s.hasSuffix(suffix), let n = Int(s.dropLast(suffix.count)) { return n }
        }
        return nil
    }

    private static func normalizedWeekday(_ s: String) -> String? {
        [
            "sun": "Sunday", "sunday": "Sunday",
            "mon": "Monday", "monday": "Monday",
            "tue": "Tuesday", "tuesday": "Tuesday",
            "wed": "Wednesday", "wednesday": "Wednesday",
            "thu": "Thursday", "thursday": "Thursday",
            "fri": "Friday", "friday": "Friday",
            "sat": "Saturday", "saturday": "Saturday",
        ][s]
    }

    /// Lowercase, spaces to hyphens, strip anything outside `[a-z0-9._-]`, drop leading non-alnum.
    ///
    /// Note: `.` is intentionally preserved by the sanitizer so that a
    /// malformed schedule name like `"daily."` or `"daily..snapshot"`
    /// surfaces a downstream `nil` label rather than being silently
    /// rewritten to `"daily"` / `"dailysnapshot"`. The post-PR-3
    /// validity gate is `isValidComponent`, which rejects `.` — so a
    /// dotted slug is caught at label construction with a visible
    /// error rather than disappearing into the writer.
    static func sanitizedSlug(from name: String) -> String {
        var s = name.lowercased().replacingOccurrences(of: " ", with: "-")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        s = s.unicodeScalars.filter { allowed.contains($0) }.map(String.init).joined()
        while let first = s.first, !first.isLetter, !first.isNumber { s.removeFirst() }
        return s
    }

    /// S-03 (PR-3, 2026-05-15): `.` is no longer permitted in slug
    /// components. The LaunchAgent label format is
    /// `<prefix>.<profile>.<slug>`; if either contains `.`, the
    /// resulting label has >2 components after the prefix and
    /// `LaunchAgentService.profileAndSlug` rejects it at parse —
    /// the writer would succeed but the schedule would silently
    /// disappear from the Schedules UI. Rejecting `.` here keeps
    /// writer and parser symmetric.
    private static func isValidComponent(_ s: String) -> Bool {
        guard let first = s.first, first.isLetter || first.isNumber else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
        return !s.isEmpty && s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Syntactic validity check on the label string: prefix + allowed
    /// character set + no consecutive or trailing dots. The structural
    /// "must split cleanly into <profile>.<slug>" rule lives in
    /// `LaunchAgentService.profileAndSlug` so it can reject legacy
    /// 3-component labels at parse time without rejecting them at the
    /// syntactic level (where some callers historically accept
    /// `<prefix>.<profile>` shapes too).
    static func isValidLabel(_ label: String) -> Bool {
        guard label.hasPrefix("\(labelPrefix).") else { return false }
        let tail = String(label.dropFirst(labelPrefix.count + 1))
        guard !tail.isEmpty, !tail.contains(".."), !tail.hasSuffix(".") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        return tail.unicodeScalars.allSatisfy { allowed.contains($0) }
            && !tail.components(separatedBy: ".").isEmpty
    }
}
