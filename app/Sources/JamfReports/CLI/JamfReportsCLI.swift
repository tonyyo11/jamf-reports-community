import ArgumentParser
import Foundation

/// Root of the included `jamf-reports` command-line interface (v2.4.0). The same
/// binary launches the GUI on no-args; `App/main.swift` routes a recognized
/// subcommand here. Each subcommand is a thin shell over an existing engine
/// entry point. xlsx + HTML only — PDF stays a GUI feature (WKWebView needs an
/// AppKit run loop a headless CLI lacks).
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
            SchoolCheck.self, SchoolScaffold.self, Schedules.self,
        ]
    )

    /// Recognized subcommand names — `App/main.swift` checks `argv[1]` against
    /// this (plus help/version flags) to decide CLI-vs-GUI, so double-click
    /// launch (which passes non-subcommand OS args) still opens the GUI.
    static let subcommandNames: Set<String> = [
        "generate", "collect", "html", "backup", "scaffold", "check",
        "capabilities", "diagnostic-bundle", "device", "school-check", "school-scaffold",
        "schedules",
    ]

    static func isKnownSubcommand(_ arg: String) -> Bool {
        subcommandNames.contains(arg) || ["--help", "-h", "--version"].contains(arg)
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
        stream.write(Data((line.text + "\n").utf8))
    }

    /// Print an error to stderr and exit with the given code (jamf-cli convention).
    static func fail(_ message: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
        exit(code)
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
