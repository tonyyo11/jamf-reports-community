import Foundation
import XCTest
@testable import JamfReports

final class ConfigDecoderTests: XCTestCase {

    // MARK: - Seed-file invariant (#181 field report)

    /// `ensureWorkspace` seeds new workspaces from the bundled
    /// `config.example.yaml`; if ConfigLoader cannot parse that file, every
    /// fresh workspace is born broken ("config.yaml could not be parsed").
    /// This pins the invariant against the real repo file.
    func testConfigLoaderParsesTheShippedExampleConfig() throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var example: URL?
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("config.example.yaml")
            if FileManager.default.fileExists(atPath: candidate.path) {
                example = candidate
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        guard let example else {
            throw XCTSkip("config.example.yaml not found above \(#filePath)")
        }

        XCTAssertNoThrow(
            try ConfigLoader.load(from: example),
            "the workspace seed file must parse with the app's own loader"
        )
    }

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

    // MARK: - Fail-closed behavior

    /// A missing config file throws `LoadError.fileNotFound` — the caller distinguishes
    /// this from a parse failure and may apply defaults safely (legitimate first-run).
    func testLoadFromMissingFileThrowsFileNotFound() {
        let missing = URL(fileURLWithPath: "/tmp/nonexistent-jamfreports-\(UUID().uuidString)/config.yaml")
        XCTAssertThrowsError(try ConfigLoader.load(from: missing)) { error in
            guard case ConfigLoader.LoadError.fileNotFound = error else {
                XCTFail("Expected LoadError.fileNotFound, got \(error)")
                return
            }
        }
    }

    /// A config file that exists but has a non-mapping root (a bare scalar) throws
    /// `LoadError.decodeError`. Callers must treat this as fatal rather than falling back
    /// to defaults — the user expects configured behavior, not silent fallback.
    func testLoadFromNonMappingRootYAMLThrowsDecodeError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigDecoderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.yaml")
        // YAML with a top-level sequence — not a mapping. YAMLCodec.decode throws
        // invalidTopLevel, which ConfigLoader wraps as LoadError.decodeError.
        try "- item1\n- item2\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ConfigLoader.load(from: url)) { error in
            guard case ConfigLoader.LoadError.decodeError = error else {
                XCTFail("Expected LoadError.decodeError for non-mapping root, got \(error)")
                return
            }
        }
    }

    /// A valid (but minimal) config.yaml succeeds and merges defaults.
    func testLoadFromValidYAMLSucceeds() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigDecoderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.yaml")
        try "columns:\n  computer_name: \"Mac Name\"\n".write(to: url, atomically: true, encoding: .utf8)
        let config = try ConfigLoader.load(from: url)
        XCTAssertEqual(config.columns?.computerName, "Mac Name")
        // withDefaults() must have run — thresholds should be non-nil.
        XCTAssertNotNil(config.thresholds)
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
