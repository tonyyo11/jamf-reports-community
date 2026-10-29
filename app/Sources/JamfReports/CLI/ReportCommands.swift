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
    static let configuration = CommandConfiguration(
        abstract: "Generate an xlsx workbook for a profile.",
        discussion: "With html.with_workbook: true in the profile's config.yaml, the HTML "
            + "report is written beside the workbook, with the same name and a .html extension. "
            + "A Jamf School workspace writes the School workbook and ignores --template.")
    @Option(help: "Workspace profile slug.") var profile: String
    @Option(help: "Output .xlsx path (default: the workspace's Generated Reports dir).") var output: String?
    @Option(help: "Report template id (default: full-instance).") var template: String?

    func run() async throws {
        guard ProfileService.isValid(profile) else { CLIRun.fail("invalid profile '\(profile)'") }
        if let output { CLIRun.requireSafeOutput(output) }
        let resolved = try CLIRun.resolveTemplate(template)
        let (config, dataDir) = try CLIRun.loadProfile(profile)
        let sheetFailures = try await CLIRun.exclusively(profile: profile) {
            try await write(config: config, dataDir: dataDir, template: resolved)
        }
        // After the lock is given back: `fail` exits the process.
        if sheetFailures > 0 {
            CLIRun.fail(
                "\(sheetFailures) sheet(s) failed to write (workbook still written)", code: 1)
        }
    }

    /// Returns how many sheets failed to write. Internal for tests, which reach it without the
    /// tick lock.
    func write(
        config: ReportConfig, dataDir: URL, template resolved: any ReportTemplate
    ) async throws -> Int {
        try await AttentionLog.recording(profile: profile) {
            try await writeRecording(config: config, dataDir: dataDir, template: resolved)
        }
    }

    private func writeRecording(
        config: ReportConfig, dataDir: URL, template resolved: any ReportTemplate
    ) async throws -> Int {
        let engine = ReportEngine(config: config, dataDir: dataDir, profile: profile)
        // A School workspace writes the School workbook whatever the template: the Pro
        // engine would skip every sheet.
        let isSchool = ProfileProductType.detect(from: config, profile: profile).type == .jamfSchool
        // Trust signals (Run History record + webhook digest) — best-effort,
        // additive, and mode-consistent with a scheduled jamf-cli-only run.
        // generate does not collect, so it never evaluates metric alerts.
        let signals = CLIRunSignals.begin(profile: profile, kind: .generate, config: config)
        signals.bindAttention()
        let outputURL = try output.map { URL(fileURLWithPath: $0) }
            ?? engine.resolveOutputURL(
                stem: ExportNaming.reportKind(for: .xlsx, schoolMode: isSchool), profile: profile,
                onLine: signals.teeing(CLIRun.printLogLine))
        do {
            let onLine = signals.teeing(CLIRun.printLogLine)
            let failures: [SheetFailure]
            if isSchool {
                failures = try await ReportEngine.schoolGenerate(
                    config: config, dataDir: dataDir, outputURL: outputURL, profile: profile,
                    now: signals.startedAt, onLine: onLine)
            } else {
                failures = try await engine.generate(
                    outputURL: outputURL, template: resolved, onLine: onLine)
            }
            // html.with_workbook. Before the path below, which stays the last line of
            // stdout for a script that reads it. There is no School HTML report.
            if !isSchool {
                await engine.writeHTMLWithWorkbook(
                    besideWorkbook: outputURL, template: resolved,
                    onLine: signals.teeing(CLIRun.printLogLine))
            }
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
            return failures.count
        } catch {
            await signals.finishFailure(error)
            throw error
        }
    }
}

struct Collect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Collect jamf-cli snapshots for a profile. A Jamf School workspace collects "
            + "School data and a Protect-enabled Jamf Pro one also collects Protect; a profile "
            + "of another product is refused.")
    @Option(help: "Workspace profile slug.") var profile: String
    @Option(help: "Comma-separated collection tiers (refresh,inventory,scan). Default: all.") var tiers: String?
    @Flag(help: ArgumentHelp(
        "Collect even if the profile was collected recently (Jamf Pro: today; Jamf School: "
            + "within 12 hours).")) var force = false

    static func refusal(profile: String, config: ReportConfig?) -> String? {
        CollectRouter.proRunRefusal(profile: profile, operation: "Collect", config: config)
    }

    func run() async throws {
        guard ProfileService.isValid(profile) else { CLIRun.fail("invalid profile '\(profile)'") }
        let config = collectRoutingConfig(profile: profile)
        // Before the run record, the signals and the tick lock: nothing is created for a
        // profile that belongs to another product.
        if let refusal = Self.refusal(profile: profile, config: config) { CLIRun.fail(refusal) }
        let tiers = CLIRun.parseTiers(tiers)
        try await CLIRun.exclusively(profile: profile) {
            try await Self.perform(profile: profile, tiers: tiers, force: force, config: config)
        }
    }

    /// The collect itself, in a Needs attention scope of its own. `proCollect` is the test seam.
    static func perform(
        profile: String, tiers: Set<CollectionTier>, force: Bool, config: ReportConfig?,
        proCollect: CollectRouter.ProCollect? = nil
    ) async throws {
        try await AttentionLog.recording(profile: profile) {
            // Trust signals — a CLI collect now records to Run History, evaluates
            // metric alerts, and posts the notify digest exactly like a snapshot-only
            // scheduled run. All best-effort; the exit code and stdout are unchanged.
            let signals = CLIRunSignals.begin(profile: profile, kind: .collect, config: config)
            signals.bindAttention()
            do {
                // Route through CollectRouter — not ReportEngine.collect directly —
                // so a Jamf School profile collects via schoolCollect and a
                // Protect-enabled Pro profile also runs protectCollect, matching
                // every other production collect entry point.
                try await CollectRouter.run(
                    profile: profile,
                    tiers: tiers,
                    force: force,
                    config: config,
                    workspacePaths: WorkspacePaths.self,
                    now: signals.startedAt,
                    proCollect: proCollect,
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
}

struct Html: AsyncParsableCommand {
    static let configuration =
        CommandConfiguration(
            abstract: "Generate the self-contained HTML report for a profile. Refuses a Jamf "
                + "School workspace, which has no HTML report.")
    @Option(help: "Workspace profile slug.") var profile: String
    @Option(help: "Output .html path (default: the workspace's Generated Reports dir).") var output: String?

    static func refusal(config: ReportConfig, profile: String) -> String? {
        guard ProfileProductType.detect(from: config, profile: profile).type == .jamfSchool
        else { return nil }
        return "'\(profile)' is a Jamf School workspace, which has no HTML report; "
            + "use `jamf-reports generate` for the School workbook"
    }

    func run() async throws {
        guard ProfileService.isValid(profile) else { CLIRun.fail("invalid profile '\(profile)'") }
        if let output { CLIRun.requireSafeOutput(output) }
        let (config, dataDir) = try CLIRun.loadProfile(profile)
        if let refusal = Self.refusal(config: config, profile: profile) { CLIRun.fail(refusal) }
        // Reuse the xlsx naming convention (timestamp + profile attribution),
        // swapping the extension — there's no HTML-specific path resolver.
        let defaultURL = try ReportEngine(config: config, dataDir: dataDir)
            .resolveOutputURL(stem: "report", profile: profile,
                              onLine: output == nil ? CLIRun.printLogLine : nil)
            .deletingPathExtension().appendingPathExtension("html")
        let outputURL = output.map { URL(fileURLWithPath: $0) } ?? defaultURL
        try await CLIRun.exclusively(profile: profile) {
            // No run record opens here, so its items land in the app record with no run log,
            // like the GUI's manual collect.
            try await AttentionLog.recording(profile: profile) {
                _ = try await ReportEngine.generateHTML(
                    config: config, dataDir: dataDir, outputURL: outputURL, profile: profile,
                    onLine: CLIRun.printLogLine)
            }
        }
        print(outputURL.path)
    }
}
