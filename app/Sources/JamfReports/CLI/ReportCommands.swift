import ArgumentParser
import Foundation

struct Generate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Generate an xlsx workbook for a profile.")
    @Option(help: "Workspace profile slug.") var profile: String
    @Option(help: "Output .xlsx path (default: the workspace's Generated Reports dir).") var output: String?
    @Option(help: "Report template id (default: full-instance).") var template: String?

    func run() async throws {
        guard ProfileService.isValid(profile) else { CLIRun.fail("invalid profile '\(profile)'") }
        CLIRun.fail("generate: not yet implemented", code: 2)
    }
}

struct Collect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Collect jamf-cli snapshots for a profile.")
    @Option(help: "Workspace profile slug.") var profile: String
    @Option(help: "Comma-separated collection tiers (refresh,inventory,scan). Default: all.") var tiers: String?

    func run() async throws {
        guard ProfileService.isValid(profile) else { CLIRun.fail("invalid profile '\(profile)'") }
        try await ReportEngine.collect(
            profile: profile,
            workspacePaths: WorkspacePaths.self,
            tiers: CLIRun.parseTiers(tiers),
            onLine: CLIRun.printLogLine
        )
        print("[ok] collect complete for \(profile)")
    }
}

struct Html: AsyncParsableCommand {
    static let configuration =
        CommandConfiguration(abstract: "Generate the self-contained HTML report for a profile.")
    @Option(help: "Workspace profile slug.") var profile: String
    @Option(help: "Output .html path (default: the workspace's Generated Reports dir).") var output: String?

    func run() async throws {
        guard ProfileService.isValid(profile) else { CLIRun.fail("invalid profile '\(profile)'") }
        CLIRun.fail("html: not yet implemented", code: 2)
    }
}
