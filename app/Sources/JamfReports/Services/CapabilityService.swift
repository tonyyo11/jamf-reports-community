import Foundation

// MARK: - Model

/// Whether a single `jamf-cli pro` subcommand is available in the installed binary.
enum CommandAvailability: Sendable, Equatable {
    /// Command appeared in `jamf-cli pro --help` output.
    case available
    /// Binary present but command not found in help text, or binary absent.
    case blocked
}

/// Summary of which `pro` subcommands the installed binary supports.
struct CLICapabilitySnapshot: Sendable, Equatable {
    /// Detected version string, e.g. "1.18.0". Nil when the binary is absent
    /// or version detection fails.
    let version: String?
    /// Availability keyed by the canonical subcommand name used in
    /// `CapabilityService.trackedCommands`.
    let availability: [String: CommandAvailability]

    /// Empty snapshot returned when `jamf-cli` is not installed.
    static let absent = CLICapabilitySnapshot(version: nil, availability: [:])
}

// MARK: - Service

/// Probes `jamf-cli pro --help` to determine which `pro` subcommands are
/// available in the installed binary.
///
/// Parsing strategy: extract the `Available Commands:` block (delimited by
/// `Flags:`) and check membership for the commands the app depends on.
/// This is text-based, not exit-code-based — exit-code probing is unsound
/// because some versions exit non-zero for unrecognised commands even when
/// they would otherwise succeed.
///
/// Results are cached for the service lifetime. Call `refresh()` after a
/// jamf-cli install or update.
///
/// Mirror of `PlatformCapabilityService`: `@MainActor`, injected executor,
/// pure `nonisolated static` parser, testable without a live binary.
@MainActor
@Observable
final class CapabilityService {

    /// `pro` subcommands the app depends on. These are the only names surfaced
    /// in the SourcesView matrix; all others in the help text are ignored.
    nonisolated static let trackedCommands: [String] = [
        "overview",
        "report",
        "computer-groups-smart-groups",
        "scripts",
        "packages",
        "computer-extension-attributes",
    ]

    private var cached: CLICapabilitySnapshot?
    private let executor: CLIExecutor

    init(executor: CLIExecutor) {
        self.executor = executor
    }

    /// Returns the current capability snapshot, running the probe if not cached.
    func snapshot() async -> CLICapabilitySnapshot {
        if let cached { return cached }
        let result = await Self.probe(executor: executor)
        cached = result
        return result
    }

    /// Drops the cached snapshot. Call after a jamf-cli install or version change.
    func refresh() {
        cached = nil
    }

    // MARK: - Probe

    /// Runs `jamf-cli pro --help` and returns the parsed snapshot. Static so
    /// unit tests can exercise without an instance.
    nonisolated static func probe(executor: CLIExecutor) async -> CLICapabilitySnapshot {
        // Locate binary once; nil means not installed → return empty snapshot.
        guard let bin = ExecutableLocator.locate("jamf-cli") else {
            return .absent
        }
        // Version lookup is nonisolated+synchronous; safe on any thread.
        let version = JamfCLIInstaller.installedVersion(at: bin)
        return await buildSnapshot(version: version, executor: executor)
    }

    /// Builds a snapshot from the executor output. Separated from `probe` so
    /// tests can bypass `ExecutableLocator` (not available on CI) and exercise
    /// the parsing and availability-mapping logic in isolation.
    nonisolated static func buildSnapshot(
        version: String?,
        executor: CLIExecutor
    ) async -> CLICapabilitySnapshot {
        let helpData: Data
        do {
            helpData = try await executor.execute(.proHelp)
        } catch {
            // Executor failed — mark all tracked commands blocked.
            let availability = Dictionary(
                uniqueKeysWithValues: trackedCommands.map { ($0, CommandAvailability.blocked) }
            )
            return CLICapabilitySnapshot(version: version, availability: availability)
        }

        let text = String(data: helpData, encoding: .utf8) ?? ""
        let available = parseAvailableCommands(from: text)
        let availability = Dictionary(
            uniqueKeysWithValues: trackedCommands.map { cmd in
                (cmd, available.contains(cmd) ? CommandAvailability.available : .blocked)
            }
        )
        return CLICapabilitySnapshot(version: version, availability: availability)
    }

    // MARK: - Parser

    /// Extracts the set of `pro` subcommand names from `jamf-cli pro --help` output.
    ///
    /// Anchors on the `Available Commands:` header so that `Usage:`, `Examples:`,
    /// and the long description before it are ignored. Stops collecting at the first
    /// line matching `^Flags:` (cobra convention). Each command line in the block
    /// has the form `  <name>  <description>` — two or more leading spaces, then
    /// the name (non-whitespace), then more whitespace, then description.
    ///
    /// `nonisolated static` so tests can call it synchronously.
    nonisolated static func parseAvailableCommands(from helpText: String) -> Set<String> {
        var result: Set<String> = []
        var inCommandsBlock = false

        for line in helpText.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)

            // Enter the commands block when we see the header.
            if !inCommandsBlock {
                if raw.trimmingCharacters(in: .whitespaces) == "Available Commands:" {
                    inCommandsBlock = true
                }
                continue
            }

            // Exit on the Flags: section header (or any non-indented non-empty line
            // that follows the commands block, which cobra uses for subsequent sections).
            if raw.hasPrefix("Flags:") || raw.hasPrefix("Global Flags:") {
                break
            }

            // cobra command lines are indented by exactly two spaces, then the name,
            // then two or more spaces, then the description. Skip blank lines.
            guard raw.hasPrefix("  "), !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
                // A blank line or non-indented line between sections — keep scanning;
                // cobra sometimes emits a blank line before "Flags:".
                if !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Non-empty non-indented line after commands block = new section.
                    break
                }
                continue
            }

            // Drop the leading two spaces, then split on whitespace to get the name.
            let trimmed = String(raw.dropFirst(2))
            if let name = trimmed.split(whereSeparator: \.isWhitespace).first {
                let cmd = String(name)
                // Cobra emits "help" as a synthetic command — skip it.
                if cmd != "help" {
                    result.insert(cmd)
                }
            }
        }

        return result
    }
}
