import Foundation
import XCTest
@testable import JamfReports

final class ConfigDoctorServiceTests: XCTestCase {

    // MARK: - Helpers

    private func makeConfig(_ yaml: String) throws -> ReportConfig {
        try ConfigLoader.loadFromString(yaml)
    }

    private func row(_ rows: [DoctorRow], id: String) -> DoctorRow? {
        rows.first { $0.id == id }
    }

    /// A clean computer config whose mapped columns exactly match `cleanHeaders`.
    private let cleanYAML = """
    columns:
      computer_name: "Computer Name"
      serial_number: "Serial Number"
      operating_system: "Operating System Version"
      last_checkin: "Last Check-in"
    compliance:
      enabled: false
    """

    private let cleanHeaders = [
        "Computer Name", "Serial Number", "Operating System Version", "Last Check-in",
    ]

    // MARK: - Parse

    func testParseErrorEmitsSingleFailRow() {
        let rows = ConfigDoctorService.evaluate(
            config: nil,
            parseError: "compliance.bands[0]: missing 'label'",
            csvHeaders: nil,
            csvFamily: nil,
            eaCoverageNames: []
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, "config.parse")
        XCTAssertEqual(rows.first?.severity, .fail)
        XCTAssertEqual(rows.first?.detail, "compliance.bands[0]: missing 'label'")
    }

    // MARK: - Clean config

    func testCleanConfigHasNoFailRows() throws {
        let config = try makeConfig(cleanYAML)
        let rows = ConfigDoctorService.evaluate(
            config: config,
            parseError: nil,
            csvHeaders: cleanHeaders,
            csvFamily: .computers,
            eaCoverageNames: []
        )
        XCTAssertFalse(rows.contains { $0.severity == .fail }, "clean config must not fail")
        // Required-column pass rows must be present.
        XCTAssertEqual(row(rows, id: "required.columns.computer_name")?.severity, .pass)
        // CSV-mapped pass rows must be present.
        XCTAssertEqual(row(rows, id: "columns.computer_name")?.severity, .pass)
    }

    // MARK: - Missing column

    func testConfiguredColumnMissingFromHeadersFails() throws {
        let config = try makeConfig(cleanYAML)
        // Drop the serial header so the mapped 'Serial Number' is not present.
        let headers = ["Computer Name", "Operating System Version", "Last Check-in"]
        let rows = ConfigDoctorService.evaluate(
            config: config,
            parseError: nil,
            csvHeaders: headers,
            csvFamily: .computers,
            eaCoverageNames: []
        )
        let serial = row(rows, id: "columns.serial_number")
        XCTAssertEqual(serial?.severity, .fail)
        XCTAssertTrue(serial?.detail.contains("Serial Number") ?? false)
    }

    // MARK: - Duplicate mapping

    func testDuplicateColumnMappingWarns() throws {
        let yaml = """
        columns:
          computer_name: "Asset"
          serial_number: "Asset"
          operating_system: "OS"
          last_checkin: "Checkin"
        """
        let config = try makeConfig(yaml)
        let rows = ConfigDoctorService.evaluate(
            config: config,
            parseError: nil,
            csvHeaders: nil,
            csvFamily: nil,
            eaCoverageNames: []
        )
        let dup = rows.first { $0.id.hasPrefix("columns.duplicate.") }
        XCTAssertNotNil(dup, "two fields mapped to 'Asset' must warn")
        XCTAssertEqual(dup?.severity, .warn)
    }

    // MARK: - Compliance enabled but empty columns

    func testComplianceEnabledWithEmptyColumnsWarns() throws {
        let yaml = """
        compliance:
          enabled: true
          failures_count_column: ""
          failures_list_column: ""
        """
        let config = try makeConfig(yaml)
        let rows = ConfigDoctorService.evaluate(
            config: config,
            parseError: nil,
            csvHeaders: nil,
            csvFamily: nil,
            eaCoverageNames: []
        )
        XCTAssertEqual(row(rows, id: "compliance.columns")?.severity, .warn)
    }

    // MARK: - Baselines vs EA results

    func testBaselineNotSeenInEAResultsWarns() throws {
        let yaml = """
        compliance:
          enabled: true
          failures_count_column: "Failed mSCP Count"
          baseline_label: "STIG"
        """
        let config = try makeConfig(yaml)
        let rows = ConfigDoctorService.evaluate(
            config: config,
            parseError: nil,
            csvHeaders: nil,
            csvFamily: nil,
            eaCoverageNames: ["Some Other EA"]
        )
        let baseline = rows.first { $0.id.hasPrefix("compliance.baseline.") }
        XCTAssertEqual(baseline?.severity, .warn)
    }

    func testBaselineCheckSkippedWhenNoEACoverage() throws {
        let yaml = """
        compliance:
          enabled: true
          failures_count_column: "Failed mSCP Count"
          baseline_label: "STIG"
        """
        let config = try makeConfig(yaml)
        let rows = ConfigDoctorService.evaluate(
            config: config,
            parseError: nil,
            csvHeaders: nil,
            csvFamily: nil,
            eaCoverageNames: []
        )
        let baseline = rows.first { $0.id.hasPrefix("compliance.baseline.") }
        XCTAssertNil(baseline, "no EA coverage means the baseline check is skipped")
    }

    func testBaselineSeenInEAResultsPasses() throws {
        let yaml = """
        compliance:
          enabled: true
          failures_count_column: "Failed mSCP Count"
          baseline_label: "STIG"
        """
        let config = try makeConfig(yaml)
        let rows = ConfigDoctorService.evaluate(
            config: config,
            parseError: nil,
            csvHeaders: nil,
            csvFamily: nil,
            eaCoverageNames: ["failed mscp count"]  // case-insensitive match
        )
        let baseline = rows.first { $0.id.hasPrefix("compliance.baseline.") }
        XCTAssertEqual(baseline?.severity, .pass)
    }

    // MARK: - Suggest

    func testBetterScoringHeaderProducesSuggestRow() throws {
        // 'serial_number' is mapped to a weak substring match while the CSV also
        // contains the canonical 'Serial Number' header (an exact hint match).
        let yaml = """
        columns:
          computer_name: "Computer Name"
          serial_number: "Device Serial"
          operating_system: "Operating System Version"
          last_checkin: "Last Check-in"
        """
        let config = try makeConfig(yaml)
        let headers = [
            "Computer Name", "Device Serial", "Serial Number",
            "Operating System Version", "Last Check-in",
        ]
        let rows = ConfigDoctorService.evaluate(
            config: config,
            parseError: nil,
            csvHeaders: headers,
            csvFamily: .computers,
            eaCoverageNames: []
        )
        let serial = row(rows, id: "columns.serial_number")
        XCTAssertEqual(serial?.severity, .suggest,
                       "a stronger header should yield a suggest, not a plain pass")
        XCTAssertTrue(serial?.detail.contains("Serial Number") ?? false)
    }
}
