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

        var args = ["generate", "--config", config.path]
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
            arguments: command.arguments + ["collect", "--config", config.path],
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
            arguments: command.arguments + ["collect", "--config", config.path],
            onLine: onLine
        )
        guard collectExit == 0 else { return collectExit }

        onLine(.init(timestamp: Date(), level: .info, text: "[info] generating report from cached snapshots"))
        var generateArgs = ["generate", "--config", config.path]
        if let csv = csvPath { generateArgs.append(contentsOf: ["--csv", csv]) }
        return await run(executable: command.executable, arguments: command.arguments + generateArgs, onLine: onLine)
    }

    nonisolated func validateConnection(profile: String, onLine: @Sendable @escaping (LogLine) -> Void) async -> Int32 {
        guard let bin = ExecutableLocator.locate("jamf-cli") else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] jamf-cli not found"))
            return -1
        }
        return await run(executable: bin, arguments: ["config", "validate", "-p", profile], onLine: onLine)
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
        var args = ["html", "--config", config.path, "--no-open"]
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
        var args = ["inventory-csv", "--config", config.path]
        if let path = outFile { args.append(contentsOf: ["--out-file", path]) }
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
        var args = ["check", "--config", config.path]
        if let csv = csvPath { args.append(contentsOf: ["--csv", csv]) }
        return await run(executable: command.executable, arguments: command.arguments + args, onLine: onLine)
    }

    func resolveJRCCommand() -> (executable: URL, arguments: [String])? {
        if let jrc = locate("jrc") {
            return (jrc, [])
        }
        guard let script = resolveJRCScript(),
              let python = locate("python3") ?? locate("python") else {
            return nil
        }
        return (python, [script.path])
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
            return config
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
        return config
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
