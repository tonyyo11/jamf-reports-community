import ArgumentParser
import Foundation

struct Backup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Back up a Jamf Pro profile's config objects, and Jamf Protect too when "
            + "connected. Refuses a Jamf School or other-product profile.")
    @Option(help: "Workspace profile slug.") var profile: String

    static func refusal(profile: String) -> String? {
        CollectRouter.backupRefusal(
            profile: profile, config: collectRoutingConfig(profile: profile))
    }

    func run() async throws {
        guard ProfileService.isValid(profile) else { CLIRun.fail("invalid profile '\(profile)'") }
        // Before the tick lock and before anything is written, once: the bridge would print
        // the same refusal and ArgumentParser would print it again as an error.
        if let refusal = Self.refusal(profile: profile) { CLIRun.fail(refusal) }
        let code = try await CLIRun.exclusively(profile: profile) { () -> Int32 in
            let bridge = await MainActor.run { CLIBridge() }
            // Label like the GUI/scheduled path so a cron'd `backup` participates in
            // the same "keep newest 10" retention instead of growing unbounded.
            let label = "scheduled-\(BackupMaintenance.dateStamp())"
            let run = try await bridge.backupRun(
                profile: profile, label: label, onLine: CLIRun.printLogLine)
            let code = run.exit
            // Run housekeeping BEFORE the possible CLIRun.fail below (which exits the
            // process) so an exit-7 partial export is pruned like any other backup —
            // CLIRun.fail never returns, so housekeeping is otherwise unreachable.
            // Second caller of the shared housekeeping (the scheduled run is the other):
            // prune old scheduled backups and sweep abandoned `.tmp-*` staging dirs.
            if CLIBridge.backupOutputIsPrunable(exit: code) {
                BackupMaintenance.performPostSuccessHousekeeping(
                    profile: profile, justFinished: run.folder,
                    onLine: CLIRun.printLogLine)
            }
            return code
        }
        // Explain the exit code (cause + remediation) rather than printing a bare
        // integer — same translation the GUI and the scheduled path use.
        if code != 0 {
            CLIRun.fail(
                CLIBridge.explainExit(code, operation: "Backup for '\(profile)'"), code: code
            )
        }
    }
}

struct Scaffold: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scaffold a minimal jamf-cli config.yaml, optionally importing Extension "
            + "Attributes from a Jamf Pro CSV export once.")
    @Option(help: ArgumentHelp(
        "Path to a Jamf Pro CSV export. Its non-built-in columns are written as custom_eas "
            + "once; no column mapping is written or read. Omit to write the minimal config "
            + "alone, the same starting point the GUI's workspace step writes."
    )) var csv: String?
    @Option(help: "Output config.yaml path.") var out: String

    func run() async throws {
        CLIRun.requireSafeOutput(out)
        let outURL = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Profile-agnostic: empty slug → `jamf_cli.profile: ""` (the user sets the profile
        // when they wire it up). Like Python's `scaffold`, this OVERWRITES `--out` if it
        // exists — it's an initial-setup command. The file it replaces is copied aside first.
        guard let csv else {
            try keepCopy(of: outURL)
            try ScaffoldService.writeMinimalConfig(to: outURL, profile: "")
            SharedConfigPin.confirmWrittenConfig(at: outURL)
            print(outURL.path)
            return
        }
        let sample = try ScaffoldService.readSample(from: URL(fileURLWithPath: csv))
        let eas = ScaffoldService.proposeEAs(
            headers: sample.headers, sampleRows: sample.rows, mappedHeaders: [])
        try keepCopy(of: outURL)
        try ScaffoldService.writeConfig(to: outURL, eas: eas, profile: "")
        SharedConfigPin.confirmWrittenConfig(at: outURL)
        print(outURL.path)
    }

    /// On stderr, so stdout stays the one path a script reads.
    private func keepCopy(of url: URL) throws {
        guard let backup = try ConfigService.backUp(url) else { return }
        FileHandle.standardError.write(
            Data(("note: kept a copy of the existing file at \(backup.path)"
                + (ConfigService.backupOmitsWebhook(backup)
                    ? "; its webhook URL is not kept, so enter it again after a restore" : "")
                + "\n").utf8))
    }
}

struct Check: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check a profile's config, data accuracy and workspace, with a fix for "
            + "each finding."
    )
    @Option(help: "Workspace profile slug.") var profile: String
    @Flag(help: "Emit machine-readable JSON.") var json = false

    func run() async throws {
        guard ProfileService.isValid(profile) else { CLIRun.fail("invalid profile '\(profile)'") }
        guard json else { Foundation.exit(runCheck(profile: profile)) }

        // JSON mode reports the doctor alone. The plain path's extra lines
        // (config decoded, snapshot counts) are narration for a human reading
        // a terminal; a machine wants the findings and the verdict.
        let report = ConfigDoctorService.run(profile: profile)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = CheckJSON(
            profile: profile,
            passed: report.failCount == 0,
            counts: .init(
                pass: report.passCount, suggest: report.suggestCount,
                warn: report.warnCount, fail: report.failCount
            ),
            findings: report.rows
                .filter { $0.severity != .pass }
                .map {
                    CheckJSON.Finding(
                        id: $0.id, severity: $0.severity.rawValue,
                        title: $0.title, detail: $0.detail, fix: $0.hint
                    )
                }
        )
        print(String(decoding: try encoder.encode(payload), as: UTF8.self))
        Foundation.exit(report.failCount > 0 ? 1 : 0)
    }
}

/// Shape of `check --json`. Stable enough to gate a CI job on: `passed` and the
/// exit code agree, and `findings` carries the same fix text a human sees.
private struct CheckJSON: Encodable {
    struct Counts: Encodable {
        let pass: Int
        let suggest: Int
        let warn: Int
        let fail: Int
    }
    struct Finding: Encodable {
        let id: String
        let severity: String
        let title: String
        let detail: String
        let fix: String?
    }
    let profile: String
    let passed: Bool
    let counts: Counts
    let findings: [Finding]
}

struct Capabilities: AsyncParsableCommand {
    static let configuration =
        CommandConfiguration(abstract: "Report detected jamf-cli command capabilities.")
    // No --profile: the probe runs `jamf-cli pro --help`, which is profile-less.
    @Flag(help: "Emit machine-readable JSON.") var json = false

    func run() async throws {
        let bridge = await MainActor.run { CLIBridge() }
        let snapshot = await CapabilityService.probe(executor: DefaultCLIExecutor(bridge: bridge))
        if json {
            let commands = snapshot.availability.mapValues { $0 == .available ? "available" : "blocked" }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(CapabilityJSON(version: snapshot.version, commands: commands))
            print(String(decoding: data, as: UTF8.self))
        } else {
            print("jamf-cli " + (snapshot.version ?? "(not installed)"))
            for cmd in CapabilityService.trackedCommands {
                let state = snapshot.availability[cmd] == .available ? "available" : "blocked"
                print("  \(cmd.padding(toLength: 34, withPad: " ", startingAt: 0)) \(state)")
            }
        }
    }
}

/// `capabilities --json` payload — keeps serialization out of the model so the
/// CLI shape can evolve without touching `CLICapabilitySnapshot`.
private struct CapabilityJSON: Encodable {
    let version: String?
    let commands: [String: String]
}

struct DiagnosticBundleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diagnostic-bundle",
        abstract: "Build a redacted diagnostic bundle for a profile.",
        discussion: "Writes the zip under ~/Library/Logs/JamfReports/diagnostics/<profile> "
            + "and prints its path."
    )
    @Option(help: "Workspace profile slug.") var profile: String

    func run() async throws {
        guard ProfileService.isValid(profile) else { CLIRun.fail("invalid profile '\(profile)'") }
        let url = try DiagnosticBundleService.generate(profile: profile)
        print(url.path)
    }
}

struct Device: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Look up one device by serial number or id. "
            + "Refuses a profile of another product.")
    @Option(help: "Workspace profile slug.") var profile: String
    @Option(help: "Device serial number or id.") var id: String

    /// No onLine: `CLIRun.fail` is the one place the text is printed.
    static func refusal(profile: String) async -> String? {
        await CLIBridge.refusesProCommand(profile: profile, operation: "Device lookup", onLine: nil)
    }

    func run() async throws {
        guard ProfileService.isValid(profile) else { CLIRun.fail("invalid profile '\(profile)'") }
        if let refusal = await Self.refusal(profile: profile) { CLIRun.fail(refusal) }
        let bridge = await MainActor.run { CLIBridge() }
        guard let result = await bridge.deviceDetailWithProvenance(
            profile: profile, deviceID: id, onLine: CLIRun.printLogLine) else {
            CLIRun.fail("device lookup failed for '\(id)' (auth, or device not found)", code: 1)
        }
        if result.fromCache {
            FileHandle.standardError.write(
                Data("warning: live lookup failed — returned last-known-good cache\n".utf8))
        }
        CLIRun.write(String(decoding: result.data, as: UTF8.self) + "\n", to: .standardOutput)
    }
}

struct SchoolCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "school-check",
        abstract: "Validate a Jamf School workspace. Refuses a profile that is not one."
    )
    @Option(help: "Workspace profile slug.") var profile: String

    func run() async throws {
        guard ProfileService.isValid(profile) else { CLIRun.fail("invalid profile '\(profile)'") }
        Foundation.exit(runSchoolCheck(profile: profile))
    }
}
