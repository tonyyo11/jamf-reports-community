import ArgumentParser
import Foundation

/// Load `profile`'s config tolerantly for `CollectRouter`'s product-type
/// routing: a missing workspace or unparseable `config.yaml` degrades to nil
/// (which `CollectRouter` treats as Jamf Pro) rather than failing the command,
/// mirroring `CLIBridge.collect`'s identical fallback.
func collectRoutingConfig(profile: String) -> ReportConfig? {
    ProfileService.workspaceURL(for: profile).flatMap {
        try? ConfigLoader.load(from: $0.appendingPathComponent("config.yaml"))
    }
}

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
            if !failures.isEmpty {
                // Same marker text the scheduled path records (main.swift), so
                // RunHistoryService.isPartialRun recognizes a partially-failed
                // CLI generate the same way it does a scheduled one.
                signals.recorder?.record(partialRunMarker(sheetFailures: failures.count))
            }
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
        let config = collectRoutingConfig(profile: profile)
        // Trust signals — a CLI collect now records to Run History, evaluates
        // metric alerts, and posts the notify digest exactly like a snapshot-only
        // scheduled run. All best-effort; the exit code and stdout are unchanged.
        let signals = CLIRunSignals.begin(profile: profile, kind: .collect, config: config)
        do {
            // Route through CollectRouter — not ReportEngine.collect directly —
            // so a Jamf School profile collects via schoolCollect and a
            // Protect-enabled Pro profile also runs protectCollect, matching
            // every other production collect entry point.
            try await CollectRouter.run(
                profile: profile,
                tiers: CLIRun.parseTiers(tiers),
                force: force,
                config: config,
                workspacePaths: WorkspacePaths.self,
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
