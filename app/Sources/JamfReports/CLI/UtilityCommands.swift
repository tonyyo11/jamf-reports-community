import ArgumentParser
import Foundation

struct Backup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Back up Jamf Pro config objects for a profile.")
    @Option(help: "Workspace profile slug.") var profile: String

    func run() async throws {
        guard ProfileService.isValid(profile) else { CLIRun.fail("invalid profile '\(profile)'") }
        let bridge = await MainActor.run { CLIBridge() }
        // Label like the GUI/scheduled path so a cron'd `backup` participates in
        // the same "keep newest 10" retention instead of growing unbounded.
        let label = "scheduled-\(BackupMaintenance.dateStamp())"
        let code = try await bridge.backup(profile: profile, label: label, onLine: CLIRun.printLogLine)
        // Run housekeeping BEFORE the possible CLIRun.fail below (which exits the
        // process) so an exit-7 partial export is pruned like any other backup —
        // CLIRun.fail never returns, so housekeeping is otherwise unreachable.
        // Third caller of the shared housekeeping (GUI + scheduled are the others):
        // prune old scheduled backups and sweep abandoned `.tmp-*` staging dirs.
        if CLIBridge.backupOutputIsPrunable(exit: code) {
            BackupMaintenance.performPostSuccessHousekeeping(profile: profile, onLine: CLIRun.printLogLine)
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
        abstract: "Scaffold a config.yaml, from a Jamf Pro CSV export or as a minimal "
            + "jamf-cli-only config.")
    @Option(help: ArgumentHelp(
        "Path to a Jamf Pro CSV export. Omit to write a minimal jamf-cli-only config "
            + "(no column mapping) — the same starting point the GUI's \"Skip for now\" "
            + "onboarding path writes."
    )) var csv: String?
    @Option(help: "Output config.yaml path.") var out: String

    func run() async throws {
        CLIRun.requireSafeOutput(out)
        let outURL = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Profile-agnostic: empty slug → `jamf_cli.profile: ""` (matches the old
        // Python `scaffold`; the user sets the profile when they wire it up). Like
        // Python's `scaffold`, this OVERWRITES `--out` if it exists — it's an
        // initial-setup command; the GUI re-scaffold does a non-destructive merge.
        guard let csv else {
            // Same shape the GUI onboarding "Skip for now" path writes, and the
            // same unconditional-overwrite semantics as the CSV branch below.
            try ScaffoldService.writeMinimalConfig(to: outURL, profile: "")
            print(outURL.path)
            return
        }
        let result = try ScaffoldService.matchColumns(from: URL(fileURLWithPath: csv), profile: "")
        try ScaffoldService.writeConfig(to: outURL, result: result, profile: "")
        print(outURL.path)
    }
}

struct Check: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check a profile's config, data accuracy and workspace, with a fix for each finding."
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
        let bridge = await MainActor.run { CLIBridge() }
        guard let result = await bridge.deviceDetailWithProvenance(
            profile: profile, deviceID: id, onLine: CLIRun.printLogLine) else {
            CLIRun.fail("device lookup failed for '\(id)' (auth, or device not found)", code: 1)
        }
        if result.fromCache {
            FileHandle.standardError.write(
                Data("warning: live lookup failed — returned last-known-good cache\n".utf8))
        }
        print(String(decoding: result.data, as: UTF8.self))
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
