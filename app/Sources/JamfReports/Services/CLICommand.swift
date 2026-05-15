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

    /// `jamf-cli -p <profile> pro sg templates --output json` (jamf-cli PR #205, target release TBD).
    /// Lists the 23 curated smart-group templates. Read-only.
    case proSmartGroupTemplates(profile: String)

    /// `jamf-cli -p <profile> pro sg preview --template <slug> [params...] --output json` (target release TBD).
    /// Returns the JSON body that `apply` would POST. No API call to Jamf.
    /// `params` is a list of `--<name>=<value>` pairs the template requires.
    case proSmartGroupPreview(profile: String, templateSlug: String, params: [String: String])

    /// `jamf-cli -p <profile> pro sg apply --template <slug> --name <NAME> [params...]
    /// [--recalculate] [--dry-run] [--yes] --output json` (target release TBD).
    /// **Destructive** — creates or updates a smart group by name in the live tenant
    /// when `dryRun` is false. Always pass `yes: true` from a GUI context (no TTY for
    /// interactive prompts). Caller must already have collected explicit user consent.
    case proSmartGroupApply(
        profile: String,
        templateSlug: String,
        smartGroupName: String,
        params: [String: String],
        recalculate: Bool,
        dryRun: Bool
    )

    /// `jamf-cli -p <profile> pro sg verify-templates --output json` (target release TBD).
    /// Smoke-tests every template against the live tenant. Diagnostic; reports OK /
    /// zero-match / error per template. Read-only by default (cleans up after itself).
    case proSmartGroupVerifyTemplates(profile: String)

    /// Argv passed to `jamf-cli`; the executor prepends the resolved binary path.
    ///
    /// Returns an empty array when the profile slug fails validation. All construction
    /// sites should already validate, so this is a defense-in-depth guard against
    /// path traversal via an unvalidated profile name reaching `Process.arguments`.
    var argv: [String] {
        guard ProfileService.isValid(profile) else {
            assertionFailure(
                "CLICommand.argv called with invalid profile '\(profile)' " +
                "— caller should validate before constructing CLICommand"
            )
            return []
        }
        switch self {
        case .proAuthToken(let profile):
            return ["-p", profile, "pro", "auth", "token", "--output", "json", "--no-input"]
        case .schoolDepDevicesList(let profile):
            return ["-p", profile, "school", "dep-devices", "list", "--output", "json"]
        case .schoolIBeaconsList(let profile):
            return ["-p", profile, "school", "ibeacons", "list", "--output", "json"]
        case .proSmartGroupTemplates(let profile):
            return ["-p", profile, "pro", "sg", "templates", "--output", "json"]
        case .proSmartGroupPreview(let profile, let slug, let params):
            var args = ["-p", profile, "pro", "sg", "preview", "--template", slug]
            args.append(contentsOf: Self.paramFlags(params))
            args.append(contentsOf: ["--output", "json"])
            return args
        case let .proSmartGroupApply(profile, slug, name, params, recalculate, dryRun):
            var args = [
                "-p", profile, "pro", "sg", "apply",
                "--template", slug,
                "--name", name,
            ]
            args.append(contentsOf: Self.paramFlags(params))
            if recalculate { args.append("--recalculate") }
            if dryRun { args.append("--dry-run") }
            // GUI context has no TTY for confirmation prompts. Callers must
            // already have collected explicit user consent before constructing
            // this case — see SmartGroupApplyService.
            args.append("--yes")
            args.append(contentsOf: ["--output", "json"])
            return args
        case .proSmartGroupVerifyTemplates(let profile):
            return ["-p", profile, "pro", "sg", "verify-templates", "--output", "json"]
        }
    }

    /// Serializes `params` into a stable, sorted list of `--<name>=<value>` flags.
    /// Sorted so the argv is deterministic — easier to test and to compare across runs.
    private static func paramFlags(_ params: [String: String]) -> [String] {
        params.sorted(by: { $0.key < $1.key })
            .map { "--\($0.key)=\($0.value)" }
    }

    /// Cache key under which JSON results should be persisted, when applicable.
    /// Returns `nil` for commands whose output is transient (e.g. token status,
    /// preview, apply) or for diagnostic commands (verify-templates).
    var snapshotKind: SnapshotKind? {
        switch self {
        case .proAuthToken:
            return nil
        case .schoolDepDevicesList:
            return .schoolDepDevices
        case .schoolIBeaconsList:
            return .schoolIBeacons
        case .proSmartGroupTemplates:
            return .smartGroupTemplates
        case .proSmartGroupPreview, .proSmartGroupApply, .proSmartGroupVerifyTemplates:
            return nil
        }
    }
}

/// Stable identifiers for on-disk JSON snapshots produced by `CLICommand` runs.
///
/// String values double as filename stems under `<workspace>/jamf-cli-data/`.
enum SnapshotKind: String, Sendable, Equatable {
    case schoolDepDevices = "school-dep-devices"
    case schoolIBeacons = "school-ibeacons"
    case smartGroupTemplates = "smart-group-templates"
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
        let argv = command.argv
        guard !argv.isEmpty else {
            throw CLIExecutorError.invalidProfile(profile)
        }
        guard let bin = ExecutableLocator.locate("jamf-cli") else {
            throw CLIExecutorError.binaryNotFound("jamf-cli")
        }
        // `runAndCapture` captures stdout into `data` and streams stderr via `onLine`.
        // We need stderr to classify auth/HTTP/network errors thrown by jamf-cli,
        // so accumulate it here rather than discarding it.
        let stderrBuffer = StderrAccumulator()
        let (exitCode, data) = await bridge.runAndCapture(
            executable: bin,
            arguments: argv,
            onLine: { line in stderrBuffer.append(line.text) }
        )
        guard exitCode == 0 else {
            throw CLIExecutorError.nonZeroExit(code: exitCode, stderr: stderrBuffer.snapshot())
        }
        return data
    }
}

/// Thread-safe stderr line collector used by `DefaultCLIExecutor`. `runAndCapture`
/// invokes `onLine` from a background `readabilityHandler` queue, so the buffer
/// is locked on append. `snapshot()` joins lines back with newlines for pattern
/// matching by the typed-error classifiers.
private final class StderrAccumulator: @unchecked Sendable {
    private var lines: [String] = []
    private let lock = NSLock()

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

extension CLICommand {
    /// Profile slug embedded in the command. All current cases carry one.
    var profile: String {
        switch self {
        case .proAuthToken(let profile),
             .schoolDepDevicesList(let profile),
             .schoolIBeaconsList(let profile),
             .proSmartGroupTemplates(let profile),
             .proSmartGroupVerifyTemplates(let profile):
            return profile
        case .proSmartGroupPreview(let profile, _, _):
            return profile
        case .proSmartGroupApply(let profile, _, _, _, _, _):
            return profile
        }
    }
}
