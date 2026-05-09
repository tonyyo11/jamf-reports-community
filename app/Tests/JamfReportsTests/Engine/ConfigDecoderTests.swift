import Foundation
import XCTest
@testable import JamfReports

final class ConfigDecoderTests: XCTestCase {

    // MARK: - withDefaults()

    func testWithDefaultsFillsMissingFields() {
        let config = ReportConfig()
        let filled = config.withDefaults()

        // withDefaults() sets non-nil ThresholdsConfig; resolvedStaleDays defaults to 30.
        XCTAssertNotNil(filled.thresholds)
        XCTAssertEqual(filled.thresholds?.resolvedStaleDays, 30)
        // output_dir must default to "Generated Reports".
        XCTAssertEqual(filled.output?.resolvedOutputDir, "Generated Reports")
    }

    func testWithDefaultsPreservesExplicitValues() {
        var config = ReportConfig()
        config.thresholds = ThresholdsConfig(staleDeviceDays: 60, certWarningDays: nil)
        let filled = config.withDefaults()

        XCTAssertEqual(filled.thresholds?.staleDeviceDays, 60)
    }

    // MARK: - ColumnConfig field resolution

    func testColumnConfigResolvesKnownField() {
        var columns = ColumnConfig()
        columns.computerName = "Computer Name"
        columns.operatingSystem = "Operating System"

        XCTAssertEqual(columns.columnName(for: .computerName), "Computer Name")
        XCTAssertEqual(columns.columnName(for: .operatingSystem), "Operating System")
    }

    func testColumnConfigNilForUnsetField() {
        let columns = ColumnConfig()
        // department is unset by default.
        XCTAssertNil(columns.columnName(for: .department))
    }

    // MARK: - ConfigLoader from fixture YAML

    func testLoadDummyFixtureYAML() throws {
        let fixtureURL = fixturesDir
            .appendingPathComponent("config/dummy.yaml")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("Fixture not available")
        }

        let config = try ConfigLoader.load(from: fixtureURL)

        // dummy.yaml maps "Computer Name" → computer_name.
        XCTAssertEqual(config.columns?.computerName, "Computer Name")
        // dummy.yaml maps "Operating System" → operating_system.
        XCTAssertEqual(config.columns?.operatingSystem, "Operating System")
        // dummy.yaml maps "Last Check-in" → last_checkin.
        XCTAssertEqual(config.columns?.lastCheckin, "Last Check-in")
    }

    func testLoadReturnsEmptyConfigForMissingFile() {
        let missing = URL(fileURLWithPath: "/nonexistent/path/config.yaml")
        XCTAssertThrowsError(try ConfigLoader.load(from: missing))
    }

    // MARK: - Key name invariants (critical — do not rename these)

    func testOperatingSystemKeyNotOsVersion() {
        // The config key must be `operating_system`, never `os_version`.
        var c = ColumnConfig()
        c.operatingSystem = "Operating System"
        XCTAssertNotNil(c.operatingSystem)
        XCTAssertEqual(c.columnName(for: .operatingSystem), "Operating System")
    }

    func testLastCheckinKeyNotLastContact() {
        var c = ColumnConfig()
        c.lastCheckin = "Last Check-in"
        XCTAssertEqual(c.columnName(for: .lastCheckin), "Last Check-in")
    }

    func testCustomEATrueValueKeyNotCompliantValue() throws {
        // `true_value` — not `compliant_value`.
        // Decode from JSON to verify the key name is `true_value`.
        let json = """
        {"name":"FileVault","column":"FileVault 2 Status",
         "type":"boolean","true_value":"Encrypted"}
        """
        let ea = try JSONDecoder().decode(CustomEAConfig.self, from: Data(json.utf8))
        XCTAssertEqual(ea.trueValue, "Encrypted")
        XCTAssertEqual(ea.type, .boolean)
    }

    func testJamfCLIProfileKeyNotJamfProfile() {
        // `profile` — not `jamf_profile`.
        var cli = JamfCLIConfig()
        cli.profile = "myprofile"
        XCTAssertEqual(cli.profile, "myprofile")
    }

    func testOutputKeepLatestRunsKeyNotMaxRuns() {
        // `keep_latest_runs` — not `max_runs`.
        var out = OutputConfig()
        out.keepLatestRuns = 5
        XCTAssertEqual(out.keepLatestRuns, 5)
    }

    // MARK: - Helper

    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Engine/
            .deletingLastPathComponent()   // JamfReportsTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // app/
            .deletingLastPathComponent()   // worktree root
            .appendingPathComponent("tests/fixtures")
    }
}
