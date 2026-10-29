import ArgumentParser
import Foundation

/// Root of the included `jamf-reports` command-line interface (v2.4.0). The same
/// binary launches the GUI on no-args; `App/main.swift` routes here when
/// `routesToCLI` accepts the first argument. Each subcommand is a thin shell over
/// an existing engine entry point. xlsx + HTML only — PDF stays a GUI feature
/// (WKWebView needs an AppKit run loop a headless CLI lacks).
///
/// The availability annotation is required because we invoke `main()` manually
/// (the binary is GUI-first, so there's no `@main` to synthesize it); without
/// it ArgumentParser's async runtime refuses to dispatch `run()`.
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct JamfReportsCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jamf-reports",
        abstract: "Generate Jamf Pro and Jamf School fleet reports from the command line.",
        subcommands: [
            Generate.self, Collect.self, Html.self, Backup.self, Scaffold.self,
            Check.self, Capabilities.self, DiagnosticBundleCommand.self, Device.self,
            SchoolCheck.self, Schedules.self, Verify.self,
        ]
    )

    /// Recognized subcommand names. With `help` and the help/version flags they make up
    /// `isKnownSubcommand`, which is how `routesToCLI` still sends `--help` to the CLI.
    static let subcommandNames: Set<String> = [
        "generate", "collect", "html", "backup", "scaffold", "check",
        "capabilities", "diagnostic-bundle", "device", "school-check", "schedules", "verify",
    ]

    /// `help` is ArgumentParser's built-in subcommand (`jamf-reports help generate`),
    /// so it routes here without being in `subcommandNames`, which lists only the
    /// subcommands this root declares.
    static func isKnownSubcommand(_ arg: String) -> Bool {
        subcommandNames.contains(arg) || ["help", "--help", "-h", "--version"].contains(arg)
    }

    /// `App/main.swift`'s CLI-vs-GUI test for `argv[1]`: a known subcommand or help flag, or
    /// any word that is not a flag, so ArgumentParser rejects a removed or mistyped subcommand
    /// instead of the app opening (#207 G31). Launch Services arguments (`-psn_…`, `-NS…`,
    /// `-Apple…`) start with `-` and still open the GUI.
    static func routesToCLI(_ firstArgument: String) -> Bool {
        isKnownSubcommand(firstArgument) || !firstArgument.hasPrefix("-")
    }
}

/// Shared CLI helpers — tier parsing, log-line stream routing, fatal exit.
enum CLIRun {
    /// Parse a `--tiers refresh,inventory,scan` CSV into a `CollectionTier` set;
    /// nil or all-unrecognized → every tier (the engine default).
    static func parseTiers(_ csv: String?) -> Set<CollectionTier> {
        guard let csv else { return Set(CollectionTier.allCases) }
        let tiers = csv.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { CollectionTier(rawValue: $0) }
        return tiers.isEmpty ? Set(CollectionTier.allCases) : Set(tiers)
    }

    /// Route engine log lines: warnings/errors → stderr, progress/ok → stdout.
    static func printLogLine(_ line: CLIBridge.LogLine) {
        let stream: FileHandle = (line.level == .fail || line.level == .warn)
            ? .standardError : .standardOutput
        write(renderedLogLine(line), to: stream)
    }

    /// Writes `text`, made safe for a terminal when `stream` is one; a pipe or file gets the
    /// bytes unchanged, so a script reads the value as jamf-cli or the cache holds it.
    static func write(_ text: String, to stream: FileHandle) {
        let shown = isatty(stream.fileDescriptor) == 1 ? terminalSafe(text) : text
        stream.write(Data(shown.utf8))
    }

    /// `text` with C0 controls other than tab and newline, DEL, C1 controls, the line and
    /// paragraph separators and the bidi controls written as `\uNNNN`: a device name or server
    /// error can otherwise clear the screen, retitle the window, set the clipboard or reorder
    /// what the line shows. JSON stays valid JSON for the same value.
    static func terminalSafe(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if (value < 0x20 && value != 0x09 && value != 0x0A) || (0x7F...0x9F).contains(value)
                || (0x2028...0x202E).contains(value) || (0x2066...0x2069).contains(value) {
                out.append(contentsOf: String(format: "\\u%04x", value).unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// The bytes written for `line`: credentials masked, since jamf-cli echoes its own errors
    /// and a terminal or a scheduler's capture keeps them.
    static func renderedLogLine(_ line: CLIBridge.LogLine) -> String {
        LogRedactor.redact(line.text) + "\n"
    }

    /// Runs `body` holding the tick lock, as a GUI collect, a report and the tick do, so this
    /// command cannot overlap one of them or another command. When another live process holds
    /// it, nothing runs: one line on stderr and exit `TickRunner.queuedExitCode`, the code a
    /// tick turned away by the lock exits with. `fail` exits without unwinding, so a command
    /// that ends with a failure exit returns what it would have exited with and fails after.
    /// Past the lock's time limit the process ends and `profile`'s Run History says why.
    static func exclusively<T: Sendable>(
        profile: String,
        lock: TickLock = TickLock(url: TickLock.defaultURL),
        onGiveUp: (@Sendable () -> Void)? = nil,
        _ body: () async throws -> T
    ) async throws -> T {
        let giveUp = onGiveUp ?? lockGiveUp(.command, workspaces: { [profile] })
        guard let result = try await lock.holdingForRun(onGiveUp: giveUp, body) else {
            FileHandle.standardError.write(Data("error: \(TickLock.busyMessage)\n".utf8))
            throw ExitCode(TickRunner.queuedExitCode)
        }
        return result
    }

    /// Print an error to stderr and exit with the given code (jamf-cli convention).
    static func fail(_ message: String, code: Int32 = 1) -> Never {
        write("error: " + message + "\n", to: .standardError)
        exit(code)
    }

    /// Exit unless `profile` is a name the app takes and its workspace folder is its own, before
    /// any command opens a lock, a run record or a file in it. Every subcommand that names a
    /// profile calls this first, `generate` and `html` before `loadProfile`.
    static func requireValidProfile(_ profile: String) {
        if let refusal = profileRefusal(profile) { fail(refusal) }
    }

    /// Why `profile` cannot be used here: a name the app does not take (filtered before it is
    /// printed, since it can hold control characters), or a case variant whose folder is
    /// another spelling's (`ProfileService.caseVariantRefusal`).
    static func profileRefusal(_ profile: String) -> String? {
        guard ProfileService.isValid(profile) else {
            return "invalid profile '\(ConfigSchema.displayText(profile))'"
        }
        return ProfileService.caseVariantRefusal(of: profile)
    }

    /// Reject a user-supplied output path that lands in a sensitive directory
    /// (`~/.ssh`, `~/Library`, …). The GUI applies this deny-list in `CLIBridge`;
    /// the CLI calls the engine directly, so it must guard the path itself —
    /// otherwise `--output ~/.ssh/authorized_keys` would be overwritten.
    static func requireSafeOutput(_ path: String) {
        if WorkspacePaths.isSensitiveAbsolutePath(URL(fileURLWithPath: path)) {
            fail("refusing to write into a sensitive path: \(path)")
        }
    }

    /// Load a profile's parsed config + snapshot data dir — the setup the
    /// `generate`/`html` commands share. A missing workspace is an operator
    /// error (immediate exit); config decode errors propagate to ArgumentParser.
    static func loadProfile(_ profile: String) throws -> (config: ReportConfig, dataDir: URL) {
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            fail("no workspace for profile '\(profile)'")
        }
        let config = try ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml"))
        // Before the first folder is resolved, so a drifted shared-config folder reads as its
        // safe value from here on.
        SharedConfigPin.checkpoint(profile: profile, onLine: printLogLine)
        let dataDir = try WorkspacePaths.dataDir(for: profile)
        return (config, dataDir)
    }

    /// Resolve the `--template` id. nil → `FullInstanceTemplate` (the CLI default,
    /// matching GUI generation). `custom` needs a sheet selection the CLI doesn't
    /// expose, so it's rejected like any unknown id rather than silently downgraded.
    static func resolveTemplate(_ id: String?) throws -> any ReportTemplate {
        guard let id else { return FullInstanceTemplate() }
        let known = TemplateResolver.allTemplates.map(\.identifier).filter { $0 != "custom" }
        guard known.contains(id) else {
            throw ValidationError(
                "unknown template '\(id)'. Known: \(known.joined(separator: ", "))")
        }
        return TemplateResolver.resolve(identifier: id)
    }
}
