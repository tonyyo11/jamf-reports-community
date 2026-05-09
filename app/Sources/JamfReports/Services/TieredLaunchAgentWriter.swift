import Foundation
import Darwin

/// Writes tier-specific LaunchAgent plists for per-profile background collection.
///
/// One plist per profile per tier, labeled:
///   `com.github.tonyyo11.jamf-reports-community.<profile>.<tier>`
///
/// All plists are user agents in `~/Library/LaunchAgents`. No LaunchDaemons,
/// no `sudo`. `RunAtLoad` is always false for every tier to avoid a full
/// inventory dump on every login; the in-app `RefreshCoordinator` handles the
/// first-run refresh.
///
/// Each agent runs `jamf-cli -p <profile> pro collect` on the tier's cadence.
/// The `collect` subcommand maps to `CLIBridge.collect`, which is the
/// established Python-side orchestration path.
enum TieredLaunchAgentWriter {

    // MARK: - Errors

    enum WriterError: Error, LocalizedError {
        case invalidProfile(String)
        case outsideSafeDir(URL)

        var errorDescription: String? {
            switch self {
            case .invalidProfile(let p):
                return "Profile '\(p)' contains invalid characters."
            case .outsideSafeDir(let u):
                return "Path is outside ~/Library/LaunchAgents: \(u.lastPathComponent)"
            }
        }
    }

    // MARK: - Label

    /// Canonical label for a profile+tier combination.
    ///
    /// Format: `com.github.tonyyo11.jamf-reports-community.<profile>.<tier>`
    static func label(for profile: String, tier: ScheduleTier) -> String {
        "\(LaunchAgentWriter.labelPrefix).\(profile).\(tier.rawValue)"
    }

    // MARK: - Write

    /// Write a tier plist for `profile` to `~/Library/LaunchAgents`.
    ///
    /// Uses `replaceItemAt(_:withItemAtURL:backupItemName:options:)` for atomic
    /// update so a crash during the write never leaves a corrupt plist on disk.
    ///
    /// - Parameters:
    ///   - profile: Validated jamf-cli profile slug.
    ///   - tier: The collection tier whose cadence this agent runs on.
    ///   - jamfCLIPath: Absolute path to the `jamf-cli` binary. Caller should
    ///     resolve via `ExecutableLocator.locate("jamf-cli")`.
    ///   - load: When `true`, bootstrap the agent into launchd after writing.
    @discardableResult
    static func write(
        profile: String,
        tier: ScheduleTier,
        jamfCLIPath: URL,
        load: Bool = false
    ) async throws -> URL {
        guard ProfileService.isValid(profile) else {
            throw WriterError.invalidProfile(profile)
        }

        let agentLabel = label(for: profile, tier: tier)
        let agentsDir = LaunchAgentService.agentsDir
        let plistURL = agentsDir.appendingPathComponent("\(agentLabel).plist")

        // Boundary check: plist must live inside ~/Library/LaunchAgents.
        let safeDir = agentsDir.resolvingSymlinksInPath().standardizedFileURL
        let resolved = plistURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(safeDir.path + "/") || resolved.path == safeDir.path else {
            throw WriterError.outsideSafeDir(plistURL)
        }

        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/JamfReports/\(agentLabel)", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)

        let plistContent: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [
                jamfCLIPath.path,
                "-p", profile,
                "pro", "collect",
                "--output", "json",
            ],
            "StartInterval": tier.intervalSeconds,
            // RunAtLoad is always false — the in-app RefreshCoordinator handles the
            // first refresh. A login-time daemon startup for a 24-hour cold scan
            // would be expensive and surprising.
            "RunAtLoad": false,
            "StandardOutPath": logDir.appendingPathComponent("stdout.log").path,
            "StandardErrorPath": logDir.appendingPathComponent("stderr.log").path,
            "EnvironmentVariables": baseLaunchEnvironment(),
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: plistContent,
            format: .xml,
            options: 0
        )

        // Atomic write via a temp file + replaceItemAt.
        let tmp = agentsDir.appendingPathComponent(".\(agentLabel).tmp.plist")
        try data.write(to: tmp, options: .atomic)

        do {
            _ = try FileManager.default.replaceItemAt(plistURL, withItemAt: tmp)
        } catch {
            // replaceItemAt throws when the destination does not exist yet.
            // moveItem is also atomic on the same volume, so this is safe.
            try FileManager.default.moveItem(at: tmp, to: plistURL)
        }

        if load {
            _ = await launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        }

        return plistURL
    }

    /// Remove and unload a tier plist for `profile`.
    static func remove(profile: String, tier: ScheduleTier) async throws {
        guard ProfileService.isValid(profile) else {
            throw WriterError.invalidProfile(profile)
        }
        let agentLabel = label(for: profile, tier: tier)
        _ = await launchctl(["bootout", "gui/\(getuid())/\(agentLabel)"])
        let plistURL = LaunchAgentService.agentsDir.appendingPathComponent("\(agentLabel).plist")
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        try FileManager.default.removeItem(at: plistURL)
    }

    // MARK: - Private helpers

    private static func baseLaunchEnvironment() -> [String: String] {
        [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        ]
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
}
