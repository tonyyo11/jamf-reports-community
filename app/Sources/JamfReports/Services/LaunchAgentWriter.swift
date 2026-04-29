import Foundation
import Darwin

/// LaunchAgent label and command helpers for the Python-owned automation flow.
///
/// The macOS app no longer serializes LaunchAgent plists. It shells out to
/// `jamf-reports-community.py launchagent-setup`, which owns the plist schema,
/// status-file path, log paths, CSV inbox behavior, and launchd loading.
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

    // MARK: - Python launchagent-setup arguments

    static func setupPlan(
        for schedule: Schedule,
        configURL: URL,
        workspaceURL: URL,
        load: Bool
    ) throws -> SetupPlan {
        guard ProfileService.isValid(schedule.profile) else {
            throw WriterError.invalidProfile(schedule.profile)
        }
        guard let agentLabel = label(for: schedule) else {
            throw WriterError.invalidSlug(sanitizedSlug(from: schedule.name))
        }
        let cadence = try setupCadence(from: schedule.schedule)
        var args = [
            "launchagent-setup",
            "--config", configURL.path,
            "--profile", schedule.profile,
            "--label", agentLabel,
            "--mode", schedule.mode.rawValue,
            "--schedule", cadence.schedule,
            "--time-of-day", cadence.timeOfDay,
            "--workspace-dir", workspaceURL.path,
        ]
        if let weekday = cadence.weekday {
            args.append(contentsOf: ["--weekday", weekday])
        }
        if let day = cadence.dayOfMonth {
            args.append(contentsOf: ["--day-of-month", String(day)])
        }
        if !load {
            args.append(contentsOf: ["--disabled", "--skip-load"])
        }
        return SetupPlan(
            label: agentLabel,
            arguments: args,
            plistURL: LaunchAgentService.agentsDir.appendingPathComponent("\(agentLabel).plist")
        )
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
        do {
            let plan = try manualRunPlan(for: label)
            return await runManualPlan(plan, onLine: onLine)
        } catch {
            onLine(.init(
                timestamp: Date(),
                level: .fail,
                text: "[error] \(error.localizedDescription)"
            ))
            return -1
        }
    }

    /// Delete a generated Python-owned plist.
    static func delete(_ label: String) throws {
        guard isValidLabel(label) else {
            throw WriterError.outsideSafeDir(
                LaunchAgentService.agentsDir.appendingPathComponent("\(label).plist")
            )
        }
        let plistURL = LaunchAgentService.agentsDir.appendingPathComponent("\(label).plist")
        let safeDir = LaunchAgentService.agentsDir.resolvingSymlinksInPath()
        guard plistURL.resolvingSymlinksInPath().path.hasPrefix(safeDir.path) else {
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
        guard ProfileService.isValid(schedule.profile) else { return nil }
        let slug = sanitizedSlug(from: schedule.name)
        guard isValidComponent(slug) else { return nil }
        let candidate = "\(labelPrefix).\(schedule.profile).\(slug)"
        return isValidLabel(candidate) ? candidate : nil
    }

    // MARK: - Private helpers

    private struct CadenceOptions {
        let schedule: String
        let timeOfDay: String
        let weekday: String?
        let dayOfMonth: Int?
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
            case .unsupportedCommand(let label): "LaunchAgent \(label) is not a generated JRC run command."
            case .unsafePath(let path):         "LaunchAgent path is outside the profile workspace: \(path)"
            case .notExecutable(let path):      "LaunchAgent executable is not runnable: \(path)"
            case .untrustedExecutable(let path): "LaunchAgent executable is outside the trusted Python locations: \(path)"
            case .untrustedScript(let path):    "LaunchAgent script is not the trusted JRC script: \(path)"
            }
        }
    }

    /// Trusted Python interpreter locations for the manual Run-now flow.
    ///
    /// A tampered plist could otherwise point ``ProgramArguments[0]`` at any
    /// executable on disk and use the GUI's `runNow` to launch it. The
    /// allowlist limits us to system Python, Homebrew, the python.org framework
    /// installer, Xcode developer tools, and ``pyenv`` shims. Exact binary
    /// paths and directory roots are separate so a loose prefix such as
    /// `/usr/local/bin/python` does not also trust `/usr/local/bin/python-evil`.
    private static let trustedPythonExactPaths: Set<String> = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return Set([
            "/usr/bin/python",
            "/usr/bin/python3",
            "/usr/local/bin/python",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python",
            "/opt/homebrew/bin/python3",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/python",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/python3",
            "\(home)/.pyenv/shims/python",
            "\(home)/.pyenv/shims/python3",
        ].map { canonicalPath($0) })
    }()

    private static let trustedPythonDirectoryRoots: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/Library/Frameworks/Python.framework/Versions",
            "\(home)/.pyenv/versions/",
        ].map { canonicalPath($0) }
    }()

    private static let trustedHomebrewRoots = [
        "/opt/homebrew/opt",
        "/opt/homebrew/Cellar",
        "/usr/local/opt",
        "/usr/local/Cellar",
    ].map { canonicalPath($0) }

    /// True when ``path`` resolves to a trusted Python interpreter.
    static func isTrustedPythonExecutable(_ path: String) -> Bool {
        let resolvedURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard isPythonExecutableName(resolvedURL.lastPathComponent) else { return false }
        guard FileManager.default.isExecutableFile(atPath: resolvedURL.path) else { return false }
        let resolved = resolvedURL.path
        if let bundled = bundledPythonURL(), sameResolvedPath(resolvedURL, bundled) {
            return true
        }
        return trustedPythonExactPaths.contains(resolved)
            || trustedPythonDirectoryRoots.contains { isPath(resolved, inside: $0) }
            || isHomebrewPythonPath(resolved)
    }

    private static func bundledPythonURL() -> URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("python", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("python3")
    }

    /// Candidate JRC script paths used by the app bridge.
    static func trustedJRCScriptCandidates() -> [URL] {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return [
            cwd.appendingPathComponent("jamf-reports-community.py"),
            cwd.deletingLastPathComponent().appendingPathComponent("jamf-reports-community.py"),
            Bundle.main.resourceURL?.appendingPathComponent("jamf-reports-community.py"),
        ].compactMap { $0 }
    }

    /// True when ``path`` is the same resolved file the app would invoke.
    static func isTrustedJRCScript(_ path: String) -> Bool {
        let fm = FileManager.default
        let expanded = (path as NSString).expandingTildeInPath
        let script = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL
        guard script.lastPathComponent == "jamf-reports-community.py",
              fm.fileExists(atPath: script.path) else {
            return false
        }
        return trustedJRCScriptCandidates().contains { candidate in
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            return fm.fileExists(atPath: resolved.path) && resolved.path == script.path
        }
    }

    private static func setupCadence(from raw: String) throws -> CadenceOptions {
        let normalized = raw
            .replacingOccurrences(of: " · ", with: " ")
            .replacingOccurrences(of: "\u{00B7}", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let tokens = normalized.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard tokens.count >= 2 else { throw WriterError.cadenceParseError(raw) }

        let timeOfDay = try parseHHMM(tokens.last!, raw: raw)
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
            do { try p.run() } catch { cont.resume(returning: -1) }
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
        guard args[2] == "launchagent-run",
              args[1].hasSuffix("jamf-reports-community.py"),
              isPythonExecutableName(URL(fileURLWithPath: args[0]).lastPathComponent) else {
            throw ManualRunError.unsupportedCommand(label)
        }
        guard isTrustedJRCScript(args[1]) else {
            throw ManualRunError.untrustedScript(args[1])
        }
        guard let configURL = argumentPath("--config", in: args, root: root),
              isExpectedConfigURL(configURL, root: root) else {
            throw ManualRunError.unsafePath("config")
        }
        guard let statusURL = argumentPath("--status-file", in: args, root: root),
              isExpectedStatusURL(statusURL, label: label, root: root) else {
            throw ManualRunError.unsafePath("status file")
        }
        if let argProfile = argumentValue("--profile", in: args), argProfile != profile {
            throw ManualRunError.malformedPlist("profile does not match label")
        }

        let executable = URL(fileURLWithPath: args[0])
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ManualRunError.notExecutable(executable.path)
        }
        guard isTrustedPythonExecutable(executable.path) else {
            throw ManualRunError.untrustedExecutable(executable.path)
        }

        let workingDirectory = validatedWorkspaceURL(
            plist["WorkingDirectory"] as? String,
            root: root
        ) ?? root
        guard let stdoutURL = validatedWorkspaceURL(plist["StandardOutPath"] as? String, root: root),
              isExpectedStdoutURL(stdoutURL, label: label, root: root),
              let stderrURL = validatedWorkspaceURL(plist["StandardErrorPath"] as? String, root: root),
              isExpectedStderrURL(stderrURL, label: label, root: root) else {
            throw ManualRunError.unsafePath("stdout or stderr log")
        }

        return ManualRunPlan(
            label: label,
            executable: executable,
            arguments: Array(args.dropFirst()),
            workingDirectory: workingDirectory,
            environment: launchEnvironment(from: plist),
            stdoutURL: stdoutURL,
            stderrURL: stderrURL
        )
    }

    private static func runManualPlan(
        _ plan: ManualRunPlan,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) async -> Int32 {
        await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(
                    at: plan.stdoutURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.createDirectory(
                    at: plan.stderrURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
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

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private static func sameResolvedPath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path
            == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func isPath(_ path: String, inside root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private static func isHomebrewPythonPath(_ path: String) -> Bool {
        trustedHomebrewRoots.contains { root in
            guard isPath(path, inside: root) else { return false }
            let relative = path.dropFirst(root.count).split(separator: "/")
            guard let formula = relative.first else { return false }
            return formula == "python" || formula.hasPrefix("python@")
        }
    }

    private static func isPythonExecutableName(_ name: String) -> Bool {
        if name == "python" || name == "python3" { return true }
        guard name.hasPrefix("python3.") else { return false }
        return name.dropFirst("python3.".count).allSatisfy(\.isNumber)
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
        var env = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": safeLaunchPath,
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONNOUSERSITE": "1",
            "PYTHONUNBUFFERED": "1",
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
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
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
        handle.write(data)
    }

    private static func emit(
        _ data: Data,
        stderr: Bool,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
            let classified = classifyManualLine(line)
            let level: CLIBridge.LogLevel = stderr && classified == .info ? .warn : classified
            onLine(.init(timestamp: Date(), level: level, text: String(line)))
        }
    }

    private static func classifyManualLine(_ line: Substring) -> CLIBridge.LogLevel {
        let lower = line.lowercased()
        if lower.contains("[ok]") { return .ok }
        if lower.contains("[warn]") { return .warn }
        if lower.contains("[fatal]") || lower.contains("[error]") || lower.contains("traceback") {
            return .fail
        }
        return .info
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
    static func sanitizedSlug(from name: String) -> String {
        var s = name.lowercased().replacingOccurrences(of: " ", with: "-")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        s = s.unicodeScalars.filter { allowed.contains($0) }.map(String.init).joined()
        while let first = s.first, !first.isLetter, !first.isNumber { s.removeFirst() }
        return s
    }

    private static func isValidComponent(_ s: String) -> Bool {
        guard let first = s.first, first.isLetter || first.isNumber else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        return !s.isEmpty && s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func isValidLabel(_ label: String) -> Bool {
        guard label.hasPrefix("\(labelPrefix).") else { return false }
        let tail = String(label.dropFirst(labelPrefix.count + 1))
        guard !tail.isEmpty, !tail.contains(".."), !tail.hasSuffix(".") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        return tail.unicodeScalars.allSatisfy { allowed.contains($0) }
            && !tail.components(separatedBy: ".").isEmpty
    }
}
