import Foundation

/// Resolve CLI binaries from GUI launches, where `Process` does not inherit a
/// login-shell PATH. `jamf-cli` may be installed by Homebrew or directly from a
/// GitHub/pkg release into `/usr/local/bin`.
enum ExecutableLocator {
    private static let candidatePaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    static func locate(_ binary: String) -> URL? {
        for dir in candidatePaths {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(binary)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(binary)
        if FileManager.default.isExecutableFile(atPath: cwd.path) {
            return cwd
        }
        return nil
    }
}

/// Wraps invocations of the underlying `jamf-reports-community` Python script (`jrc`)
/// and `jamf-cli`. The GUI is a thin shell over the CLI — every flow round-trips here.
///
/// The bridge is intentionally async-boundary-safe: it never blocks the main thread,
/// streams stdout/stderr into a callback so the Runs screen can render lines as they
/// arrive, and reports the final exit code so callers can color the `EXIT n` pill.
@MainActor
@Observable
final class CLIBridge {

    enum BridgeError: Error, LocalizedError {
        case binaryNotFound(String)
        case launchFailed(String)
        var errorDescription: String? {
            switch self {
            case .binaryNotFound(let bin): "Could not locate \(bin) on PATH."
            case .launchFailed(let msg):   "Failed to launch process: \(msg)"
            }
        }
    }

    enum LogLevel: String, Sendable { case info, ok, warn, fail }
    struct LogLine: Sendable, Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: LogLevel
        let text: String
    }

    func locate(_ binary: String) -> URL? {
        ExecutableLocator.locate(binary)
    }

    var isJRCAvailable: Bool { resolveJRCCommand() != nil }
    var isJamfCLIAvailable: Bool { locate("jamf-cli") != nil }

    func jrcDisplayPath() -> String? {
        resolveJRCScript()?.path ?? locate("jrc")?.path
    }

    /// Run an arbitrary command, streaming each line through `onLine`. Returns the
    /// process exit code. Marked `nonisolated` so it can be awaited off the main actor.
    nonisolated func run(
        executable: URL,
        arguments: [String],
        cwd: URL? = nil,
        environment: [String: String]? = nil,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async -> Int32 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if let cwd { process.currentDirectoryURL = cwd }
            if let environment { process.environment = environment }

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
                for line in s.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
                    onLine(.init(timestamp: Date(), level: classify(line), text: String(line)))
                }
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
                for line in s.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
                    onLine(.init(timestamp: Date(), level: .warn, text: String(line)))
                }
            }

            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: proc.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                onLine(.init(timestamp: Date(), level: .fail, text: "[fatal] \(error.localizedDescription)"))
                continuation.resume(returning: -1)
            }
        }
    }

    /// Fluent helper for the most common CLI flows the GUI surfaces.
    func generate(profile: String, csvPath: String?, onLine: @Sendable @escaping (LogLine) -> Void) async -> Int32 {
        guard let command = resolveJRCCommand() else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] jrc or jamf-reports-community.py not found"))
            return -1
        }
        guard let config = await ensureWorkspace(profile: profile, command: command, onLine: onLine) else {
            return -1
        }

        var args = ["generate", "--config", config.path, "--profile", profile]
        if let csv = csvPath { args.append(contentsOf: ["--csv", csv]) }
        return await run(executable: command.executable, arguments: command.arguments + args, onLine: onLine)
    }

    func collect(profile: String, onLine: @Sendable @escaping (LogLine) -> Void) async -> Int32 {
        guard let command = resolveJRCCommand() else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] jrc or jamf-reports-community.py not found"))
            return -1
        }
        guard let config = await ensureWorkspace(profile: profile, command: command, onLine: onLine) else {
            return -1
        }
        return await run(
            executable: command.executable,
            arguments: command.arguments + ["collect", "--config", config.path, "--profile", profile],
            onLine: onLine
        )
    }

    func collectThenGenerate(
        profile: String,
        csvPath: String?,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async -> Int32 {
        guard let command = resolveJRCCommand() else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] jrc or jamf-reports-community.py not found"))
            return -1
        }
        guard let config = await ensureWorkspace(profile: profile, command: command, onLine: onLine) else {
            return -1
        }

        onLine(.init(timestamp: Date(), level: .info, text: "[info] collecting jamf-cli snapshots for \(profile)"))
        let collectExit = await run(
            executable: command.executable,
            arguments: command.arguments + ["collect", "--config", config.path, "--profile", profile],
            onLine: onLine
        )
        guard collectExit == 0 else { return collectExit }

        onLine(.init(timestamp: Date(), level: .info, text: "[info] generating report from cached snapshots"))
        var generateArgs = ["generate", "--config", config.path, "--profile", profile]
        if let csv = csvPath { generateArgs.append(contentsOf: ["--csv", csv]) }
        return await run(executable: command.executable, arguments: command.arguments + generateArgs, onLine: onLine)
    }

    nonisolated func validateConnection(profile: String, onLine: @Sendable @escaping (LogLine) -> Void) async -> Int32 {
        guard ProfileService.isValid(profile) else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] invalid profile name: \(profile)"))
            return -1
        }
        guard let bin = ExecutableLocator.locate("jamf-cli") else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] jamf-cli not found"))
            return -1
        }
        return await run(executable: bin, arguments: ["-p", profile, "config", "validate"], onLine: onLine)
    }

    nonisolated func deviceDetail(profile: String, deviceID: String) async -> Data? {
        let trimmedID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ProfileService.isValid(profile),
              !trimmedID.isEmpty,
              let workspace = ProfileService.workspaceURL(for: profile) else {
            return nil
        }

        let devicesDir = workspace
            .appendingPathComponent("jamf-cli-data", isDirectory: true)
            .appendingPathComponent("devices", isDirectory: true)
        let cache = devicesDir.appendingPathComponent(deviceCacheFilename(trimmedID))
        if let bin = ExecutableLocator.locate("jamf-cli") {
            let partial = devicesDir.appendingPathComponent(".\(cache.lastPathComponent).partial")
            let exit = await runDeviceDetailProcess(
                executable: bin,
                arguments: [
                    "-p", profile, "pro", "device", trimmedID,
                    "--output", "json", "--no-input", "--out-file", partial.path,
                ],
                outputDirectory: devicesDir
            )
            if exit == 0,
               let data = try? Data(contentsOf: partial),
               !data.isEmpty {
                try? FileManager.default.removeItem(at: cache)
                do {
                    try FileManager.default.moveItem(at: partial, to: cache)
                    return try? Data(contentsOf: cache)
                } catch {
                    try? data.write(to: cache, options: .atomic)
                    return data
                }
            }
            try? FileManager.default.removeItem(at: partial)
        }
        return try? Data(contentsOf: cache)
    }

    nonisolated func diffBackups(
        profile: String,
        left: URL,
        right: URL,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async -> Int32 {
        guard ProfileService.isValid(profile) else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] invalid profile name: \(profile)"))
            return -1
        }
        guard let bin = ExecutableLocator.locate("jamf-cli") else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] jamf-cli not found"))
            return -1
        }
        return await run(
            executable: bin,
            arguments: [
                "-p", profile,
                "pro", "diff",
                "--source", left.path,
                "--target", right.path,
                "--output", "plain",
                "--no-input",
            ],
            onLine: onLine
        )
    }

    func generateHTML(
        profile: String,
        outFile: String?,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async -> Int32 {
        guard let command = resolveJRCCommand() else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] jrc or jamf-reports-community.py not found"))
            return -1
        }
        guard let config = await ensureWorkspace(profile: profile, command: command, onLine: onLine) else {
            return -1
        }
        var args = ["html", "--config", config.path, "--profile", profile, "--no-open"]
        if let path = outFile { args.append(contentsOf: ["--out-file", path]) }
        return await run(executable: command.executable, arguments: command.arguments + args, onLine: onLine)
    }

    func exportInventoryCSV(
        profile: String,
        outFile: String?,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async -> Int32 {
        guard let command = resolveJRCCommand() else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] jrc or jamf-reports-community.py not found"))
            return -1
        }
        guard let config = await ensureWorkspace(profile: profile, command: command, onLine: onLine) else {
            return -1
        }
        var args = ["inventory-csv", "--config", config.path, "--profile", profile]
        if let path = outFile { args.append(contentsOf: ["--out-file", path]) }
        return await run(executable: command.executable, arguments: command.arguments + args, onLine: onLine)
    }

    func backup(
        profile: String,
        label: String?,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async -> Int32 {
        guard let command = resolveJRCCommand() else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] jrc or jamf-reports-community.py not found"))
            return -1
        }
        guard let config = await ensureWorkspace(profile: profile, command: command, onLine: onLine) else {
            return -1
        }
        var args = ["backup", "--config", config.path, "--profile", profile]
        if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append(contentsOf: ["--label", label])
        }
        return await run(executable: command.executable, arguments: command.arguments + args, onLine: onLine)
    }

    func check(profile: String, csvPath: String?, onLine: @Sendable @escaping (LogLine) -> Void) async -> Int32 {
        guard let command = resolveJRCCommand() else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] jrc or jamf-reports-community.py not found"))
            return -1
        }
        guard let config = await ensureWorkspace(profile: profile, command: command, onLine: onLine) else {
            return -1
        }
        var args = ["check", "--config", config.path, "--profile", profile]
        if let csv = csvPath { args.append(contentsOf: ["--csv", csv]) }
        return await run(executable: command.executable, arguments: command.arguments + args, onLine: onLine)
    }

    func initializeWorkspace(
        profile: String,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async -> Int32 {
        guard let command = resolveJRCCommand() else {
            onLine(.init(
                timestamp: Date(),
                level: .fail,
                text: "[error] jrc or jamf-reports-community.py not found"
            ))
            return -1
        }
        guard await ensureWorkspace(
            profile: profile,
            command: command,
            onLine: onLine
        ) != nil else {
            return -1
        }
        return 0
    }

    func setupLaunchAgent(
        _ schedule: Schedule,
        load: Bool,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async -> Int32 {
        guard let command = resolveJRCCommand() else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] jrc or jamf-reports-community.py not found"))
            return -1
        }
        guard let workspace = ProfileService.workspaceURL(for: schedule.profile),
              let config = await ensureWorkspace(
                profile: schedule.profile,
                command: command,
                onLine: onLine
              ) else {
            return -1
        }

        let plan: LaunchAgentWriter.SetupPlan
        do {
            plan = try LaunchAgentWriter.setupPlan(
                for: schedule,
                configURL: config,
                workspaceURL: workspace,
                load: load
            )
        } catch {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] \(error.localizedDescription)"))
            return -1
        }

        let action = load ? "writing and loading" : "writing disabled"
        onLine(.init(timestamp: Date(), level: .info, text: "[info] \(action) LaunchAgent \(plan.label)"))
        return await run(
            executable: command.executable,
            arguments: command.arguments + plan.arguments,
            onLine: onLine
        )
    }

    func resolveJRCCommand() -> (executable: URL, arguments: [String])? {
        if let script = resolveJRCScript(),
           let python = locate("python3") ?? locate("python") {
            return (python, [script.path])
        }
        if let jrc = locate("jrc") {
            return (jrc, [])
        }
        return nil
    }

    func resolveJRCScript() -> URL? {
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        let candidates = [
            cwd.appendingPathComponent("jamf-reports-community.py"),
            cwd.deletingLastPathComponent().appendingPathComponent("jamf-reports-community.py"),
            Bundle.main.resourceURL?.appendingPathComponent("jamf-reports-community.py"),
        ].compactMap { $0 }

        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    private func ensureWorkspace(
        profile: String,
        command: (executable: URL, arguments: [String]),
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async -> URL? {
        guard ProfileService.isValid(profile),
              let workspace = ProfileService.workspaceURL(for: profile) else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] invalid profile name: \(profile)"))
            return nil
        }
        let config = workspace.appendingPathComponent("config.yaml")
        if FileManager.default.fileExists(atPath: config.path) {
            return reconcileConfigProfile(config: config, profile: profile, onLine: onLine)
        }

        onLine(.init(timestamp: Date(), level: .info, text: "[info] initializing workspace for \(profile)"))
        var args = command.arguments + [
            "workspace-init",
            "--profile", profile,
            "--workspace-root", ProfileService.workspacesRoot().path,
        ]
        if let seed = bundledSeedConfig() {
            args.append(contentsOf: ["--seed-config", seed.path])
        }

        let exit = await run(executable: command.executable, arguments: args, onLine: onLine)
        guard exit == 0, FileManager.default.fileExists(atPath: config.path) else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] workspace init failed for \(profile)"))
            return nil
        }
        return reconcileConfigProfile(config: config, profile: profile, onLine: onLine)
    }

    private func reconcileConfigProfile(
        config: URL,
        profile: String,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) -> URL? {
        do {
            let text = try String(contentsOf: config, encoding: .utf8)
            var document = try YAMLCodec.decode(text)
            guard case .mapping(var root) = document.root else { return config }
            var jamfCLI = root.value(for: "jamf_cli")?.mapping ?? YAMLCodec.YAMLMapping(entries: [])
            let current = jamfCLI.value(for: "profile")?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard current != profile else { return config }

            jamfCLI.set("profile", value: .scalar(.string(profile)))
            root.set("jamf_cli", value: .mapping(jamfCLI))
            document.root = .mapping(root)
            let encoded = try YAMLCodec.encode(document, replacingTopLevelKeys: ["jamf_cli"])
            let permissions = (try? FileManager.default.attributesOfItem(atPath: config.path))
                .flatMap { $0[.posixPermissions] as? NSNumber }
            try encoded.write(to: config, atomically: true, encoding: .utf8)
            if let permissions {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: permissions],
                    ofItemAtPath: config.path
                )
            }
            onLine(.init(
                timestamp: Date(),
                level: .info,
                text: "[info] set jamf_cli.profile to \(profile) in \(config.path)"
            ))
            return config
        } catch {
            onLine(.init(
                timestamp: Date(),
                level: .fail,
                text: "[error] could not update jamf_cli.profile in \(config.path): \(error.localizedDescription)"
            ))
            return nil
        }
    }

    private func bundledSeedConfig() -> URL? {
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        let candidates = [
            cwd.appendingPathComponent("config.example.yaml"),
            cwd.deletingLastPathComponent().appendingPathComponent("config.example.yaml"),
            Bundle.main.resourceURL?.appendingPathComponent("config.example.yaml"),
        ].compactMap { $0 }
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }
}

/// Heuristic line classifier. Matches the `[ok]` / `[warn]` / `[fatal]` markers
/// emitted by `jamf-reports-community.py`'s log helpers.
private func classify(_ line: Substring) -> CLIBridge.LogLevel {
    let l = line.lowercased()
    if l.contains("[ok]") { return .ok }
    if l.contains("[warn]") { return .warn }
    if l.contains("[fatal]") || l.contains("[error]") || l.contains("traceback") { return .fail }
    return .info
}

private func runDeviceDetailProcess(
    executable: URL,
    arguments: [String],
    outputDirectory: URL
) async -> Int32 {
    await Task.detached(priority: .userInitiated) {
        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }.value
}

private func deviceCacheFilename(_ raw: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    let sanitizedScalars = raw.unicodeScalars.map { scalar in
        allowed.contains(scalar) ? Character(scalar) : "_"
    }
    let sanitized = String(sanitizedScalars)
        .trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
    let prefix = String((sanitized.isEmpty ? "device" : sanitized).prefix(80))
    return "\(prefix)-\(stableDeviceHash(raw)).json"
}

private func stableDeviceHash(_ value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return String(format: "%016llx", hash)
}
