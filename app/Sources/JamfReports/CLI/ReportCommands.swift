import ArgumentParser
import Foundation

struct Generate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Generate an xlsx workbook for a profile.")
    @Option(help: "Workspace profile slug.") var profile: String
    @Option(help: "Output .xlsx path (default: the workspace's Generated Reports dir).") var output: String?
    @Option(help: "Report template id (default: full-instance).") var template: String?

    func run() async throws {
        guard ProfileService.isValid(profile) else { CLIRun.fail("invalid profile '\(profile)'") }
        let resolved = try CLIRun.resolveTemplate(template)
        let (config, dataDir) = try CLIRun.loadProfile(profile)
        let engine = ReportEngine(config: config, dataDir: dataDir)
        let outputURL = output.map { URL(fileURLWithPath: $0) }
            ?? engine.resolveOutputURL(stem: "report", profile: profile)
        let failures = try await engine.generate(
            csvURL: nil, outputURL: outputURL, template: resolved, onLine: CLIRun.printLogLine)
        // The workbook is written even when some sheets error, so always emit the
        // path (scripts can still find the artifact); exit non-zero to flag partial.
        print(outputURL.path)
        if !failures.isEmpty {
            CLIRun.fail("\(failures.count) sheet(s) failed to write (workbook still written)", code: 1)
        }
    }
}

struct Collect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Collect jamf-cli snapshots for a profile.")
    @Option(help: "Workspace profile slug.") var profile: String
    @Option(help: "Comma-separated collection tiers (refresh,inventory,scan). Default: all.") var tiers: String?
    @Flag(help: "Collect even if a snapshot was already taken today.") var force = false

    func run() async throws {
        guard ProfileService.isValid(profile) else { CLIRun.fail("invalid profile '\(profile)'") }
        try await ReportEngine.collect(
            profile: profile,
            workspacePaths: WorkspacePaths.self,
            tiers: CLIRun.parseTiers(tiers),
            force: force,
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
        let (config, dataDir) = try CLIRun.loadProfile(profile)
        // Reuse the xlsx naming convention (timestamp + profile attribution),
        // swapping the extension — there's no HTML-specific path resolver.
        let defaultURL = ReportEngine(config: config, dataDir: dataDir)
            .resolveOutputURL(stem: "report", profile: profile)
            .deletingPathExtension().appendingPathExtension("html")
        let outputURL = output.map { URL(fileURLWithPath: $0) } ?? defaultURL
        _ = try await ReportEngine.generateHTML(
            config: config, dataDir: dataDir, outputURL: outputURL, onLine: CLIRun.printLogLine)
        print(outputURL.path)
    }
}
