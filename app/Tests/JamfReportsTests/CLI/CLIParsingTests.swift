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

    func testAllElevenSubcommandsRegistered() {
        XCTAssertEqual(JamfReportsCLI.subcommandNames.count, 11)
        XCTAssertEqual(JamfReportsCLI.configuration.subcommands.count, 11)
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

    func testCapabilitiesProfileOptionalAndJsonFlag() throws {
        let cmd = try Capabilities.parse(["--json"])
        XCTAssertNil(cmd.profile)
        XCTAssertTrue(cmd.json)
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
}
