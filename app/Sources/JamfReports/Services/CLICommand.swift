import Foundation

/// Typed representation of a single jamf-cli invocation.
///
/// Used for new W22+ commands that need argv-shape testing, mock-friendly
/// execution, and a single source of truth for command construction.
/// Existing CLIBridge methods (generate, collect, audit, deviceDetail, etc.)
/// are intentionally not migrated — see ADR-W21-clicommand-enum.md for the
/// Hybrid scope. New CLI commands should be added here as enum cases and
/// invoked through `CLIExecutor`.
///
/// Note: cases do not share a uniform flag set — each one is independent.
/// `proAuthToken` includes `--no-input` to fail fast on credential prompts
/// because it is used as a probe; the list commands omit it because they
/// run after auth has been established. When adding a new case, audit
/// whether it should include `--no-input`, `--output json`, or other flags
/// based on whether the call is interactive-friendly or pure-automation.
enum CLICommand: Sendable, Equatable {

    /// `jamf-cli -p <profile> pro auth token --output json --no-input` (v1.9+).
    case proAuthToken(profile: String)

    /// `jamf-cli -p <profile> school dep-devices list --output json` (v1.14+).
    case schoolDepDevicesList(profile: String)

    /// `jamf-cli -p <profile> school ibeacons list --output json` (v1.14+).
    case schoolIBeaconsList(profile: String)

    /// Argv passed to `jamf-cli`; the executor prepends the resolved binary path.
    var argv: [String] {
        switch self {
        case .proAuthToken(let profile):
            return ["-p", profile, "pro", "auth", "token", "--output", "json", "--no-input"]
        case .schoolDepDevicesList(let profile):
            return ["-p", profile, "school", "dep-devices", "list", "--output", "json"]
        case .schoolIBeaconsList(let profile):
            return ["-p", profile, "school", "ibeacons", "list", "--output", "json"]
        }
    }

    /// Cache key under which JSON results should be persisted, when applicable.
    /// Returns `nil` for commands whose output is transient (e.g. token status).
    var snapshotKind: SnapshotKind? {
        switch self {
        case .proAuthToken:
            return nil
        case .schoolDepDevicesList:
            return .schoolDepDevices
        case .schoolIBeaconsList:
            return .schoolIBeacons
        }
    }
}

/// Stable identifiers for on-disk JSON snapshots produced by `CLICommand` runs.
///
/// String values double as filename stems under `<workspace>/jamf-cli-data/`.
enum SnapshotKind: String, Sendable, Equatable {
    case schoolDepDevices = "school-dep-devices"
    case schoolIBeacons = "school-ibeacons"
}

/// Execution surface for `CLICommand`. Mock-friendly for ViewModel tests.
protocol CLIExecutor: Sendable {
    /// Executes `command` and returns the captured stdout.
    /// Throws if the command exits non-zero or the binary cannot be located.
    func execute(_ command: CLICommand) async throws -> Data
}

/// Errors surfaced by `DefaultCLIExecutor`.
enum CLIExecutorError: Error, Equatable {
    case binaryNotFound(String)
    case invalidProfile(String)
    case nonZeroExit(code: Int32, stderr: String)
}

/// Default `CLIExecutor` that delegates to `CLIBridge.runAndCapture` for the
/// `jamf-cli` binary located on `PATH`.
///
/// This is additive — it does not change how existing `CLIBridge` helpers
/// (generate, collect, audit, …) build their argv or run their processes.
struct DefaultCLIExecutor: CLIExecutor {
    let bridge: CLIBridge

    init(bridge: CLIBridge) {
        self.bridge = bridge
    }

    func execute(_ command: CLICommand) async throws -> Data {
        let profile = command.profile
        guard ProfileService.isValid(profile) else {
            throw CLIExecutorError.invalidProfile(profile)
        }
        guard let bin = ExecutableLocator.locate("jamf-cli") else {
            throw CLIExecutorError.binaryNotFound("jamf-cli")
        }
        let (exitCode, data) = await bridge.runAndCapture(
            executable: bin,
            arguments: command.argv,
            onLine: { _ in }
        )
        guard exitCode == 0 else {
            let stderr = String(data: data, encoding: .utf8) ?? ""
            throw CLIExecutorError.nonZeroExit(code: exitCode, stderr: stderr)
        }
        return data
    }
}

extension CLICommand {
    /// Profile slug embedded in the command. All current cases carry one.
    var profile: String {
        switch self {
        case .proAuthToken(let profile),
             .schoolDepDevicesList(let profile),
             .schoolIBeaconsList(let profile):
            return profile
        }
    }
}
