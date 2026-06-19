import ArgumentParser
import Foundation

/// Root of the included `jamf-reports` command-line interface (v2.4.0). The same
/// binary launches the GUI on no-args; `App/main.swift` routes a recognized
/// subcommand here. Each subcommand is a thin shell over an existing engine
/// entry point. xlsx + HTML only — PDF stays a GUI feature (WKWebView needs an
/// AppKit run loop a headless CLI lacks).
struct JamfReportsCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jamf-reports",
        abstract: "Generate Jamf Pro and Jamf School fleet reports from the command line.",
        subcommands: [
            Generate.self, Collect.self, Html.self, Backup.self, Scaffold.self,
            Check.self, Capabilities.self, DiagnosticBundleCommand.self, Device.self,
            SchoolCheck.self, SchoolScaffold.self,
        ]
    )

    /// Recognized subcommand names — `App/main.swift` checks `argv[1]` against
    /// this (plus help/version flags) to decide CLI-vs-GUI, so double-click
    /// launch (which passes non-subcommand OS args) still opens the GUI.
    static let subcommandNames: Set<String> = [
        "generate", "collect", "html", "backup", "scaffold", "check",
        "capabilities", "diagnostic-bundle", "device", "school-check", "school-scaffold",
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
}
