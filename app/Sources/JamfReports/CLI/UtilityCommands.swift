import ArgumentParser
import Foundation

struct Backup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Back up Jamf Pro config objects for a profile.")
    @Option(help: "Workspace profile slug.") var profile: String

    func run() async throws {
        guard ProfileService.isValid(profile) else { CLIRun.fail("invalid profile '\(profile)'") }
        CLIRun.fail("backup: not yet implemented", code: 2)
    }
}

struct Scaffold: AsyncParsableCommand {
    static let configuration =
        CommandConfiguration(abstract: "Scaffold a config.yaml from a Jamf Pro CSV export.")
    @Option(help: "Path to a Jamf Pro CSV export.") var csv: String
    @Option(help: "Output config.yaml path.") var out: String

    func run() async throws {
        CLIRun.fail("scaffold: not yet implemented", code: 2)
    }
}

struct Check: AsyncParsableCommand {
    static let configuration =
        CommandConfiguration(abstract: "Validate a profile's config.yaml and jamf-cli auth.")
    @Option(help: "Workspace profile slug.") var profile: String

    func run() async throws {
        guard ProfileService.isValid(profile) else { CLIRun.fail("invalid profile '\(profile)'") }
        Foundation.exit(runCheck(profile: profile))
    }
}

struct Capabilities: AsyncParsableCommand {
    static let configuration =
        CommandConfiguration(abstract: "Report detected jamf-cli command capabilities.")
    @Option(help: "Workspace profile slug.") var profile: String?
    @Flag(help: "Emit machine-readable JSON.") var json = false

    func run() async throws {
        CLIRun.fail("capabilities: not yet implemented", code: 2)
    }
}

struct DiagnosticBundleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diagnostic-bundle",
        abstract: "Build a redacted diagnostic bundle for a profile."
    )
    @Option(help: "Workspace profile slug.") var profile: String

    func run() async throws {
        guard ProfileService.isValid(profile) else { CLIRun.fail("invalid profile '\(profile)'") }
        let url = try DiagnosticBundleService.generate(profile: profile)
        print(url.path)
    }
}

struct Device: AsyncParsableCommand {
    static let configuration =
        CommandConfiguration(abstract: "Look up one device by serial number or id.")
    @Option(help: "Workspace profile slug.") var profile: String
    @Option(help: "Device serial number or id.") var id: String

    func run() async throws {
        guard ProfileService.isValid(profile) else { CLIRun.fail("invalid profile '\(profile)'") }
        CLIRun.fail("device: not yet implemented", code: 2)
    }
}

struct SchoolCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "school-check",
        abstract: "Validate a Jamf School profile (community-feedback-driven; provided as-is)."
    )
    @Option(help: "Workspace profile slug.") var profile: String

    func run() async throws {
        guard ProfileService.isValid(profile) else { CLIRun.fail("invalid profile '\(profile)'") }
        Foundation.exit(runSchoolCheck(profile: profile))
    }
}

struct SchoolScaffold: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "school-scaffold",
        abstract: "Scaffold a Jamf School config from a CSV (community-feedback-driven; provided as-is)."
    )
    @Option(help: "Path to a Jamf School CSV export.") var csv: String
    @Option(help: "Output config.yaml path.") var out: String

    func run() async throws {
        Foundation.exit(runSchoolScaffold(csvPath: csv, outPath: out))
    }
}
