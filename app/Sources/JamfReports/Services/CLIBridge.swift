import Foundation

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

    /// Resolve `jrc` / `jamf-cli` on PATH. Falls back to common Homebrew locations
    /// because `Process` doesn't inherit a login shell PATH.
    private let candidatePaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
    ]

    func locate(_ binary: String) -> URL? {
        for dir in candidatePaths {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(binary)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    var isJRCAvailable: Bool { locate("jrc") != nil || locate("jamf-reports-community.py") != nil }
    var isJamfCLIAvailable: Bool { locate("jamf-cli") != nil }

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
        guard let bin = locate("jrc") else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] jrc not found on PATH"))
            return -1
        }
        var args = ["generate", "--profile", profile]
        if let csv = csvPath { args.append(contentsOf: ["--csv", csv]) }
        return await run(executable: bin, arguments: args, onLine: onLine)
    }

    func collect(profile: String, onLine: @Sendable @escaping (LogLine) -> Void) async -> Int32 {
        guard let bin = locate("jrc") else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] jrc not found on PATH"))
            return -1
        }
        return await run(executable: bin, arguments: ["collect", "--profile", profile], onLine: onLine)
    }

    func check(profile: String, csvPath: String?, onLine: @Sendable @escaping (LogLine) -> Void) async -> Int32 {
        guard let bin = locate("jrc") else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] jrc not found on PATH"))
            return -1
        }
        var args = ["check", "--profile", profile]
        if let csv = csvPath { args.append(contentsOf: ["--csv", csv]) }
        return await run(executable: bin, arguments: args, onLine: onLine)
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
