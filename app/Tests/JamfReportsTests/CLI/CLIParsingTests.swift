import XCTest
import ArgumentParser
@testable import JamfReports

/// v2.4.0 CLI: dispatch routing + per-subcommand argument parsing.
final class CLIParsingTests: XCTestCase {

    func testKnownSubcommandRouting() {
        XCTAssertTrue(JamfReportsCLI.isKnownSubcommand("generate"))
        XCTAssertTrue(JamfReportsCLI.isKnownSubcommand("collect"))
        XCTAssertTrue(JamfReportsCLI.isKnownSubcommand("school-check"))
        // Retired: it wrote a `school_columns` block that nothing reads.
        XCTAssertFalse(JamfReportsCLI.isKnownSubcommand("school-scaffold"))
        XCTAssertTrue(JamfReportsCLI.isKnownSubcommand("--help"))
        // ArgumentParser's built-in `help` subcommand, as in `jamf-reports help generate`
        // (docs/wiki/07-Command-Line.md); before this it opened the app instead.
        XCTAssertTrue(JamfReportsCLI.isKnownSubcommand("help"))
        XCTAssertFalse(JamfReportsCLI.isKnownSubcommand("-NSDocumentRevisionsDebugMode"))
        // Not a subcommand, but `routesToCLI` still sends it to the CLI (below).
        XCTAssertFalse(JamfReportsCLI.isKnownSubcommand("/some/file.txt"))
    }

    /// #207 G31: any first argument that is not a flag goes to the CLI, so a removed or
    /// mistyped subcommand fails there instead of opening the app. Launch Services
    /// arguments start with `-` and still open it.
    func testEveryWordRoutesToTheCLIAndLaunchArgumentsDoNot() {
        for arg in ["school-scaffold", "genrate", "generate", "help", "--help", "-h", "--version"] {
            XCTAssertTrue(JamfReportsCLI.routesToCLI(arg), arg)
        }
        for arg in ["-psn_0_12345", "-NSDocumentRevisionsDebugMode", "-AppleLanguages"] {
            XCTAssertFalse(JamfReportsCLI.routesToCLI(arg), arg)
        }
        // A bare path is a word too: the app declares no document types, so the CLI rejects it.
        XCTAssertTrue(JamfReportsCLI.routesToCLI("/some/file.txt"))
    }

    /// What the routed word then gets: ArgumentParser's error and a non-zero exit.
    func testARemovedSubcommandFailsInTheCLI() {
        XCTAssertThrowsError(try JamfReportsCLI.parseAsRoot(["school-scaffold"])) { error in
            XCTAssertNotEqual(JamfReportsCLI.exitCode(for: error), .success)
        }
    }

    func testAllTwelveSubcommandsRegistered() {
        XCTAssertEqual(JamfReportsCLI.subcommandNames.count, 12)
        XCTAssertEqual(JamfReportsCLI.configuration.subcommands.count, 12)
    }

    func testTierParsing() {
        XCTAssertEqual(CLIRun.parseTiers("refresh,inventory").count, 2)
        XCTAssertEqual(CLIRun.parseTiers(nil), Set(CollectionTier.allCases))
        XCTAssertEqual(CLIRun.parseTiers("garbage"), Set(CollectionTier.allCases))
        XCTAssertEqual(CLIRun.parseTiers("refresh, scan"), [.refresh, .scan])
    }

    func testCollectParsesProfileAndTiers() throws {
        let cmd = try Collect.parse(["--profile", "dummy", "--tiers", "refresh,scan"])
        XCTAssertEqual(cmd.profile, "dummy")
        XCTAssertEqual(cmd.tiers, "refresh,scan")
    }

    func testCommandsRequireProfile() {
        XCTAssertThrowsError(try Collect.parse([]))
        XCTAssertThrowsError(try Check.parse([]))
        XCTAssertThrowsError(try Generate.parse([]))
    }

    func testScaffoldParsesCsvAndOut() throws {
        let cmd = try Scaffold.parse(["--csv", "/tmp/x.csv", "--out", "/tmp/config.yaml"])
        XCTAssertEqual(cmd.csv, "/tmp/x.csv")
        XCTAssertEqual(cmd.out, "/tmp/config.yaml")
    }

    func testDeviceParsesIdAndProfile() throws {
        let cmd = try Device.parse(["--profile", "dummy", "--id", "ABC123"])
        XCTAssertEqual(cmd.profile, "dummy")
        XCTAssertEqual(cmd.id, "ABC123")
    }

    func testCapabilitiesJsonFlag() throws {
        XCTAssertTrue(try Capabilities.parse(["--json"]).json)
        XCTAssertFalse(try Capabilities.parse([]).json)
    }

    func testResolveTemplateDefaultsToFullInstance() throws {
        XCTAssertEqual(try CLIRun.resolveTemplate(nil).identifier, "full-instance")
    }

    func testResolveTemplateMatchesKnownIdentifier() throws {
        XCTAssertEqual(try CLIRun.resolveTemplate("executive").identifier, "executive")
    }

    func testResolveTemplateRejectsCustom() {
        // `custom` needs a sheet selection the CLI can't supply — must reject, not downgrade.
        XCTAssertThrowsError(try CLIRun.resolveTemplate("custom"))
    }

    func testResolveTemplateRejectsUnknown() {
        XCTAssertThrowsError(try CLIRun.resolveTemplate("nonsense"))
    }

    // MARK: - collectRoutingConfig (CLI `collect` → CollectRouter tolerant load)

    func testCollectRoutingConfigIsNilForMissingWorkspace() {
        let slug = "no-such-workspace-\(UUID().uuidString.prefix(8).lowercased())"
        if let workspace = ProfileService.workspaceURL(for: slug) {
            try? FileManager.default.removeItem(at: workspace)
        }
        XCTAssertNil(collectRoutingConfig(profile: slug))
    }

    func testCollectRoutingConfigDegradesToNilOnUnparseableYAML() throws {
        let slug = "collect-routing-bad-\(UUID().uuidString.prefix(8).lowercased())"
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: slug))
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        // A top-level YAML sequence (not a mapping) trips YAMLCodec.decode's
        // `CodecError.invalidTopLevel` guard — a reliably-unparseable config,
        // unlike a stray scalar that ReportConfig's all-optional fields would
        // just decode around.
        try "- one\n- two\n".write(
            to: workspace.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        // Must degrade to nil (→ CollectRouter defaults to Jamf Pro), not throw
        // and abort the collect the way `CLIRun.loadProfile` would.
        XCTAssertNil(collectRoutingConfig(profile: slug))
    }

    func testCollectRoutingConfigLoadsValidSchoolConfig() throws {
        let slug = "collect-routing-school-\(UUID().uuidString.prefix(8).lowercased())"
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: slug))
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let yaml = "school_cli:\n  enabled: true\n  profile: \"\(slug)\"\n"
        try yaml.write(
            to: workspace.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        let config = try XCTUnwrap(collectRoutingConfig(profile: slug))
        XCTAssertEqual(ProfileProductType.detect(from: config, profile: slug).type, .jamfSchool,
                        "a real config must route School — not the nil-degrades-to-Pro default")
    }

    // MARK: - backupOutputIsPrunable (shared by the scheduled and CLI backup
    // paths — they used to spell this rule out separately and drifted)

    func testBackupOutputIsPrunableOnlyForFinalizedExports() {
        // 0 = success, 7 = partial export still finalized to backups/<ts>/.
        // Everything else left nothing on disk to prune.
        let cases: [(Int32, Bool)] = [
            (0, true), (CLIBridge.exitCodePartialFailure, true),
            (1, false), (3, false), (4, false), (5, false), (6, false),
        ]
        for (code, expected) in cases {
            XCTAssertEqual(CLIBridge.backupOutputIsPrunable(exit: code), expected,
                            "exit \(code)")
        }
    }

    /// An error thrown out of `run()` reaches ArgumentParser, which exits 1: the shell never
    /// sees 3 for expired credentials from `collect` (docs/wiki/07-Command-Line.md says so).
    func testAnEngineErrorExitsOneNotThree() {
        let expired = ReportEngineError.authExpired(profile: "p", failedCount: 2)
        XCTAssertEqual(JamfReportsCLI.exitCode(for: expired), ExitCode(1))
    }

    func testTerminalSafeEscapesControlsAndKeepsTabsAndNewlines() {
        // ESC clear-screen, OSC 52 clipboard write ending in BEL, DEL, C1 CSI, CR.
        let hostile = "Mac\u{1B}[2J\u{1B}]52;c;aGk=\u{07}\u{7F}\u{9B}31m\r\tok\n"
        XCTAssertEqual(
            CLIRun.terminalSafe(hostile),
            #"Mac\u001b[2J\u001b]52;c;aGk=\u0007\u007f\u009b31m\u000d"# + "\tok\n")
        XCTAssertEqual(CLIRun.terminalSafe("Büro-Mac — 15.7 ✓"), "Büro-Mac — 15.7 ✓")
        // Right-to-left override and isolate, and a line separator, reorder or split a line.
        XCTAssertEqual(
            CLIRun.terminalSafe("Mac\u{202E}gpj.exe\u{2066}x\u{2028}y"),
            #"Mac\u202egpj.exe\u2066x\u2028y"#)
    }

    func testTerminalSafeJSONDecodesToTheSameValue() throws {
        let name = "Mac\u{7F}\u{85}\u{9B}"
        let json = try JSONSerialization.data(withJSONObject: ["name": name])
        let shown = CLIRun.terminalSafe(String(decoding: json, as: UTF8.self))
        XCTAssertFalse(shown.unicodeScalars.contains { (0x7F...0x9F).contains($0.value) }, shown)
        let decoded = try JSONSerialization.jsonObject(with: Data(shown.utf8)) as? [String: String]
        XCTAssertEqual(decoded?["name"], name)
    }

    func testWriteLeavesBytesUnchangedWhenNotATerminal() throws {
        let pipe = Pipe()
        CLIRun.write("a\u{1B}[2Jb\n", to: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()
        let read = pipe.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(String(decoding: read, as: UTF8.self), "a\u{1B}[2Jb\n")
    }
}
