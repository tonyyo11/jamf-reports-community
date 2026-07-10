import ArgumentParser
import Foundation

struct Generate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Generate an xlsx workbook for a profile.")
    @Option(help: "Workspace profile slug.") var profile: String
    @Option(help: "Output .xlsx path (default: the workspace's Generated Reports dir).") var output: String?
    @Option(help: "Report template id (default: full-instance).") var template: String?

    func run() async throws {
        guard ProfileService.isValid(profile) else { CLIRun.fail("invalid profile '\(profile)'") }
        if let output { CLIRun.requireSafeOutput(output) }
        let resolved = try CLIRun.resolveTemplate(template)
        let (config, dataDir) = try CLIRun.loadProfile(profile)
        let engine = ReportEngine(config: config, dataDir: dataDir)
        let outputURL = output.map { URL(fileURLWithPath: $0) }
            ?? engine.resolveOutputURL(stem: "report", profile: profile)
        // Trust signals (Run History record + webhook digest) — best-effort,
        // additive, and mode-consistent with a scheduled jamf-cli-only run.
        // generate does not collect, so it never evaluates metric alerts.
        let signals = CLIRunSignals.begin(profile: profile, kind: .generate, config: config)
        do {
            let failures = try await engine.generate(
                csvURL: nil, outputURL: outputURL, template: resolved,
                onLine: signals.teeing(CLIRun.printLogLine))
            // The workbook is written even when some sheets error, so always emit
            // the path (scripts can still find the artifact); exit non-zero to
            // flag partial.
            print(outputURL.path)
            await signals.finishSuccess(artifact: outputURL, sheetFailures: failures.count)
            if !failures.isEmpty {
                CLIRun.fail(
                    "\(failures.count) sheet(s) failed to write (workbook still written)", code: 1)
            }
        } catch {
            await signals.finishFailure(error)
            throw error
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
        // Trust signals — a CLI collect now records to Run History, evaluates
        // metric alerts, and posts the notify digest exactly like a snapshot-only
        // scheduled run. All best-effort; the exit code and stdout are unchanged.
        let signals = CLIRunSignals.begin(profile: profile, kind: .collect)
        do {
            try await ReportEngine.collect(
                profile: profile,
                workspacePaths: WorkspacePaths.self,
                tiers: CLIRun.parseTiers(tiers),
                force: force,
                onLine: signals.teeing(CLIRun.printLogLine)
            )
            print("[ok] collect complete for \(profile)")
            await signals.finishSuccess()
        } catch {
            await signals.finishFailure(error)
            throw error
        }
    }
}

struct Html: AsyncParsableCommand {
    static let configuration =
        CommandConfiguration(abstract: "Generate the self-contained HTML report for a profile.")
    @Option(help: "Workspace profile slug.") var profile: String
    @Option(help: "Output .html path (default: the workspace's Generated Reports dir).") var output: String?

    func run() async throws {
        guard ProfileService.isValid(profile) else { CLIRun.fail("invalid profile '\(profile)'") }
        if let output { CLIRun.requireSafeOutput(output) }
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
