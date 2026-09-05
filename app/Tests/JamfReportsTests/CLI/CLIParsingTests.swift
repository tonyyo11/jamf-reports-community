import XCTest
import ArgumentParser
@testable import JamfReports

/// v2.4.0 CLI: dispatch routing + per-subcommand argument parsing.
final class CLIParsingTests: XCTestCase {

    func testKnownSubcommandRouting() {
        XCTAssertTrue(JamfReportsCLI.isKnownSubcommand("generate"))
        XCTAssertTrue(JamfReportsCLI.isKnownSubcommand("collect"))
        XCTAssertTrue(JamfReportsCLI.isKnownSubcommand("school-scaffold"))
        XCTAssertTrue(JamfReportsCLI.isKnownSubcommand("--help"))
        // Double-click launch passes OS args that must NOT route to the CLI:
        XCTAssertFalse(JamfReportsCLI.isKnownSubcommand("-NSDocumentRevisionsDebugMode"))
        XCTAssertFalse(JamfReportsCLI.isKnownSubcommand("/some/file.txt"))
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

    func testScaffoldRequiresCsvAndOut() throws {
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
        let yaml = "school_cli:\n  enabled: true\n  profile: \"school\"\n"
        try yaml.write(
            to: workspace.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        let config = try XCTUnwrap(collectRoutingConfig(profile: slug))
        XCTAssertEqual(ProfileProductType.detect(from: config).type, .jamfSchool,
                        "a real config must route School — not the nil-degrades-to-Pro default")
    }

    // MARK: - backupOutputIsPrunable (shared by the scheduled, GUI and CLI
    // backup paths — they used to spell this rule out separately and drifted)

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
}
