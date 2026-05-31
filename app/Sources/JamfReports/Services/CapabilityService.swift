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
        "advanced-mobile-device-searches",
        "classic-computer-groups",
        "classic-mobile-device-groups",
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
    /// Real `jamf-cli pro --help` uses named category headers (`Core Commands:`,
    /// `Computer Management:`, etc.) rather than a single `Available Commands:` block.
    /// Category headers are non-indented and colon-terminated; command rows are
    /// indented with exactly two spaces. The `Flags:`/`Global Flags:` headers
    /// terminate the command section.
    ///
    /// Capture rule: a line is a command row iff it starts with exactly two spaces,
    /// the first token (name) is followed by two or more spaces (description separator),
    /// and the name is not "help" (cobra synthetic). This discriminates against the
    /// `Usage:` line (`  jamf-cli pro [command]`) because "jamf-cli" is followed by
    /// only one space, not two.
    ///
    /// `nonisolated static` so tests can call it synchronously.
    nonisolated static func parseAvailableCommands(from helpText: String) -> Set<String> {
        var result: Set<String> = []

        for line in helpText.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)

            // Stop at the flags section — nothing after it is a command.
            if raw.hasPrefix("Flags:") || raw.hasPrefix("Global Flags:") {
                break
            }

            // Command rows start with exactly two spaces (not more).
            // Lines indented more (flag values, continuation text) are skipped.
            guard raw.hasPrefix("  "), !raw.hasPrefix("   ") else { continue }

            // After stripping the two-space indent, split on whitespace.
            // A valid command row is: <name><2+ spaces><description>.
            // The name contains no whitespace; it must be followed by at least
            // two spaces so that the Usage line `  jamf-cli pro [command]` is
            // excluded ("jamf-cli" is followed by one space, not two).
            let body = String(raw.dropFirst(2))
            guard let spaceRange = body.range(of: "  ") else { continue }
            let name = String(body[body.startIndex..<spaceRange.lowerBound])
            guard !name.isEmpty, !name.contains(" "), name != "help" else { continue }

            result.insert(name)
        }

        return result
    }
}
