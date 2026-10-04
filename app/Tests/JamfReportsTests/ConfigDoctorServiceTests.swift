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
        // With a CSV present, the CSV-presence check supersedes the bare required
        // check, so there is one pass row per column (no contradictory duplicate).
        XCTAssertEqual(row(rows, id: "columns.computer_name")?.severity, .pass)
        XCTAssertNil(row(rows, id: "required.columns.computer_name"),
                     "required rows are skipped when a CSV is present")
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

    // MARK: - Mobile required columns gated on mobile_columns

    func testComputerOnlyConfigEmitsNoMobileRequiredRows() throws {
        let config = try makeConfig(cleanYAML)  // no mobile_columns block
        let rows = ConfigDoctorService.evaluate(
            config: config, parseError: nil, csvHeaders: nil,
            csvFamily: nil, eaCoverageNames: []
        )
        XCTAssertFalse(rows.contains { $0.id.hasPrefix("required.mobile_columns") },
                       "a computer-only config must not warn on every mobile field")
    }

    func testMobileConfigEmitsMobileRequiredRows() throws {
        let yaml = """
        mobile_columns:
          device_name: "Display Name"
        """
        let config = try makeConfig(yaml)
        let rows = ConfigDoctorService.evaluate(
            config: config, parseError: nil, csvHeaders: nil,
            csvFamily: nil, eaCoverageNames: []
        )
        XCTAssertEqual(row(rows, id: "required.mobile_columns.device_name")?.severity, .pass)
        XCTAssertEqual(row(rows, id: "required.mobile_columns.serial_number")?.severity, .warn)
    }

    // MARK: - CSV family unknown

    func testUnknownCSVFamilyWarns() throws {
        let config = try makeConfig(cleanYAML)
        let rows = ConfigDoctorService.evaluate(
            config: config, parseError: nil, csvHeaders: ["Foo", "Bar"],
            csvFamily: nil, eaCoverageNames: []
        )
        XCTAssertEqual(row(rows, id: "csv.family")?.severity, .warn)
    }

    // MARK: - custom_eas

    func testBooleanCustomEAWithoutTrueValueWarns() throws {
        let yaml = """
        custom_eas:
          - name: "FileVault"
            column: "FileVault 2 Status"
            type: boolean
        """
        let config = try makeConfig(yaml)
        let rows = ConfigDoctorService.evaluate(
            config: config, parseError: nil, csvHeaders: nil,
            csvFamily: nil, eaCoverageNames: []
        )
        XCTAssertEqual(row(rows, id: "custom_ea.FileVault.true_value")?.severity, .warn)
    }

    func testCustomEAColumnMissingFromCSVFails() throws {
        let yaml = """
        custom_eas:
          - name: "FileVault"
            column: "FileVault 2 Status"
            type: text
        """
        let config = try makeConfig(yaml)
        let rows = ConfigDoctorService.evaluate(
            config: config, parseError: nil, csvHeaders: ["Computer Name"],
            csvFamily: .computers, eaCoverageNames: []
        )
        XCTAssertEqual(row(rows, id: "custom_ea.FileVault.column")?.severity, .fail)
    }

    // MARK: - custom_eas without a CSV

    /// One EA whose column is a collected EA name, one whose column is not.
    private let noCSVEAYAML = """
    custom_eas:
      - name: "FileVault"
        column: "FileVault 2 Status"
        type: text
      - name: "Battery"
        column: "Battery Health"
        type: text
    """

    /// A custom EA's sheet is built from the CSV alone; with no CSV it silently
    /// renders nothing, so the doctor has to say so.
    func testCustomEAWithoutCSVWarnsThatItProducesNothing() throws {
        let rows = ConfigDoctorService.evaluate(
            config: try makeConfig(noCSVEAYAML), parseError: nil, csvHeaders: nil,
            csvFamily: nil, eaCoverageNames: ["Some Other EA"]
        )
        let finding = try XCTUnwrap(row(rows, id: "custom_ea.Battery.no_csv"))
        XCTAssertEqual(finding.severity, .warn)
        XCTAssertTrue(finding.detail.contains("Battery Health"), "got: \(finding.detail)")
        XCTAssertTrue(finding.hint?.contains("csv-inbox") ?? false,
                      "the fix names where the CSV goes; got: \(String(describing: finding.hint))")
    }

    /// Collected as an extension attribute: the sheet still needs a CSV, but the
    /// values exist and the period report can use them — a suggestion, not a warning.
    func testCustomEAWithoutCSVOnlySuggestsWhenItsColumnIsACollectedEA() throws {
        let rows = ConfigDoctorService.evaluate(
            config: try makeConfig(noCSVEAYAML), parseError: nil, csvHeaders: nil,
            csvFamily: nil, eaCoverageNames: ["filevault 2 status"]  // case-insensitive match
        )
        let finding = try XCTUnwrap(row(rows, id: "custom_ea.FileVault.no_csv"))
        XCTAssertEqual(finding.severity, .suggest)
        XCTAssertTrue(finding.detail.contains("period report"), "got: \(finding.detail)")
        XCTAssertEqual(row(rows, id: "custom_ea.Battery.no_csv")?.severity, .warn,
                       "an EA not collected still produces nothing")
    }

    /// With a CSV, the CSV check (`custom_ea.<name>.column`) covers the EA instead.
    func testCustomEANoCSVRowIsAbsentWhenACSVIsPresent() throws {
        let rows = ConfigDoctorService.evaluate(
            config: try makeConfig(noCSVEAYAML), parseError: nil,
            csvHeaders: ["Computer Name", "FileVault 2 Status", "Battery Health"],
            csvFamily: .computers, eaCoverageNames: []
        )
        XCTAssertFalse(rows.contains { $0.id.hasSuffix(".no_csv") }, "got: \(rows.map(\.id))")
        XCTAssertEqual(row(rows, id: "custom_ea.FileVault.column")?.severity, .pass)
    }

    /// An EA with no column configured has nothing to look for.
    func testCustomEAWithEmptyColumnGetsNoNoCSVRow() throws {
        let yaml = """
        custom_eas:
          - name: "Unmapped"
            column: ""
            type: text
        """
        let rows = ConfigDoctorService.evaluate(
            config: try makeConfig(yaml), parseError: nil, csvHeaders: nil,
            csvFamily: nil, eaCoverageNames: []
        )
        XCTAssertNil(row(rows, id: "custom_ea.Unmapped.no_csv"))
    }

    /// Only `.fail` rows reach a scheduled run's log. A jamf-cli-only workspace with
    /// EAs configured is valid, so these rows must never be able to turn a run red.
    func testCustomEANoCSVRowsNeverFail() throws {
        let coverages: [[String]] = [
            [], ["FileVault 2 Status"], ["FileVault 2 Status", "Battery Health"],
        ]
        for coverage in coverages {
            let rows = ConfigDoctorService.evaluate(
                config: try makeConfig(noCSVEAYAML), parseError: nil, csvHeaders: nil,
                csvFamily: nil, eaCoverageNames: coverage
            )
            let noCSV = rows.filter { $0.id.hasSuffix(".no_csv") }
            XCTAssertEqual(noCSV.count, 2, "one row per mapped EA; coverage: \(coverage)")
            XCTAssertFalse(noCSV.contains { $0.severity == .fail }, "coverage: \(coverage)")
        }
    }

    // MARK: - platform

    func testPlatformWithoutBenchmarksRaisesNoRow() throws {
        let yaml = """
        platform:
          compliance_benchmarks: []
        """
        let config = try makeConfig(yaml)
        let rows = ConfigDoctorService.evaluate(
            config: config, parseError: nil, csvHeaders: nil,
            csvFamily: nil, eaCoverageNames: []
        )
        XCTAssertNil(row(rows, id: "platform.benchmarks"))
    }

    // MARK: - security_agents

    func testSecurityAgentEmptyConnectedValueEmitsSingleWarnWithCSV() throws {
        let yaml = """
        security_agents:
          - name: "CrowdStrike"
            column: "CrowdStrike Status"
            connected_value: ""
        """
        let config = try makeConfig(yaml)
        let rows = ConfigDoctorService.evaluate(
            config: config, parseError: nil, csvHeaders: ["CrowdStrike Status"],
            csvFamily: .computers, eaCoverageNames: []
        )
        let connected = rows.filter { $0.id.contains("connected_value") }
        XCTAssertEqual(connected.count, 1, "CSV + structural must not both emit")
        XCTAssertEqual(connected.first?.severity, .warn)
    }

    func testSecurityAgentEmptyColumnWarnsViaStructuralWhenNoCSV() throws {
        let yaml = """
        security_agents:
          - name: "CrowdStrike"
            column: ""
            connected_value: "Installed"
        """
        let config = try makeConfig(yaml)
        let rows = ConfigDoctorService.evaluate(
            config: config, parseError: nil, csvHeaders: nil,
            csvFamily: nil, eaCoverageNames: []
        )
        XCTAssertEqual(
            row(rows, id: "security_agent.CrowdStrike.column.structural")?.severity, .warn
        )
    }

    // MARK: - Accuracy: cross-source reconciliation (check 1)

    private let reconcileYAML = """
    columns:
      serial_number: "Serial Number"
    """

    private func csvRows(serials: [String]) -> [CSVRow] {
        serials.map { ["Serial Number": $0] }
    }

    func testReconciliationWithinToleranceEmitsOK() throws {
        let config = try makeConfig(reconcileYAML)
        let csv = ConfigDoctorService.AccuracyCSV(
            columns: ["Serial Number"],
            rows: csvRows(serials: (1...100).map { "S\($0)" }),
            ageDays: 0, fileName: "export.csv"
        )
        let inputs = ConfigDoctorService.AccuracyInputs(
            csv: csv, computersCount: 105, eaRows: nil, coverageDrift: nil
        )
        let rows = ConfigDoctorService.evaluateAccuracy(config: config, inputs: inputs)
        XCTAssertEqual(row(rows, id: "accuracy.reconciliation")?.severity, .pass)
    }

    func testReconciliationDivergenceWarnsNamingBothSources() throws {
        let config = try makeConfig(reconcileYAML)
        let csv = ConfigDoctorService.AccuracyCSV(
            columns: ["Serial Number"],
            rows: csvRows(serials: (1...100).map { "S\($0)" }),
            ageDays: 0, fileName: "export.csv"
        )
        let inputs = ConfigDoctorService.AccuracyInputs(
            csv: csv, computersCount: 130, eaRows: nil, coverageDrift: nil
        )
        let rows = ConfigDoctorService.evaluateAccuracy(config: config, inputs: inputs)
        let recon = row(rows, id: "accuracy.reconciliation")
        XCTAssertEqual(recon?.severity, .warn)
        XCTAssertTrue(recon?.detail.contains("100") ?? false)
        XCTAssertTrue(recon?.detail.contains("130") ?? false)
    }

    func testReconciliationDedupesSerials() throws {
        let config = try makeConfig(reconcileYAML)
        // 200 rows but only 100 distinct serials (case-insensitive dupes).
        let dupes = (1...100).map { "S\($0)" } + (1...100).map { "s\($0)" }
        let csv = ConfigDoctorService.AccuracyCSV(
            columns: ["Serial Number"], rows: csvRows(serials: dupes),
            ageDays: 0, fileName: "export.csv"
        )
        let inputs = ConfigDoctorService.AccuracyInputs(
            csv: csv, computersCount: 100, eaRows: nil, coverageDrift: nil
        )
        let rows = ConfigDoctorService.evaluateAccuracy(config: config, inputs: inputs)
        // 100 deduped vs 100 snapshot → within tolerance despite 200 raw rows.
        XCTAssertEqual(row(rows, id: "accuracy.reconciliation")?.severity, .pass)
    }

    func testReconciliationSkippedWithFewerThanTwoSources() throws {
        let config = try makeConfig(reconcileYAML)
        let inputs = ConfigDoctorService.AccuracyInputs(
            csv: nil, computersCount: 100, eaRows: nil, coverageDrift: nil
        )
        let rows = ConfigDoctorService.evaluateAccuracy(config: config, inputs: inputs)
        XCTAssertNil(row(rows, id: "accuracy.reconciliation"),
                     "one source is not enough to reconcile")
    }

    // MARK: - Accuracy: stale CSV age (check 1b)

    func testStaleCSVAgeWarns() throws {
        let yaml = """
        thresholds:
          stale_device_days: 30
        """
        let config = try makeConfig(yaml)
        let csv = ConfigDoctorService.AccuracyCSV(
            columns: ["Serial Number"], rows: [], ageDays: 63, fileName: "old.csv"
        )
        let inputs = ConfigDoctorService.AccuracyInputs(
            csv: csv, computersCount: nil, eaRows: nil, coverageDrift: nil
        )
        let rows = ConfigDoctorService.evaluateAccuracy(config: config, inputs: inputs)
        let age = row(rows, id: "accuracy.csv_age")
        XCTAssertEqual(age?.severity, .warn)
        XCTAssertTrue(age?.detail.contains("old.csv") ?? false)
        XCTAssertTrue(age?.detail.contains("63") ?? false)
    }

    func testFreshCSVEmitsNoAgeRow() throws {
        let yaml = """
        thresholds:
          stale_device_days: 30
        """
        let config = try makeConfig(yaml)
        let csv = ConfigDoctorService.AccuracyCSV(
            columns: [], rows: [], ageDays: 5, fileName: "fresh.csv"
        )
        let inputs = ConfigDoctorService.AccuracyInputs(
            csv: csv, computersCount: nil, eaRows: nil, coverageDrift: nil
        )
        let rows = ConfigDoctorService.evaluateAccuracy(config: config, inputs: inputs)
        XCTAssertNil(row(rows, id: "accuracy.csv_age"))
    }

    // MARK: - Accuracy: per-column parse health (check 2)

    func testParseHealthWarnsOnLowRateWithSkeleton() throws {
        let yaml = """
        custom_eas:
          - name: "Battery"
            column: "Battery Health"
            type: percentage
        """
        let config = try makeConfig(yaml)
        // 8 of 10 non-empty values are non-numeric junk → 20% parse rate.
        let good = ["50", "75"]
        let bad = Array(repeating: "ERR", count: 8)
        let csv = ConfigDoctorService.AccuracyCSV(
            columns: ["Battery Health"],
            rows: (good + bad).map { ["Battery Health": $0] },
            ageDays: 0, fileName: "x.csv"
        )
        let inputs = ConfigDoctorService.AccuracyInputs(
            csv: csv, computersCount: nil, eaRows: nil, coverageDrift: nil
        )
        let rows = ConfigDoctorService.evaluateAccuracy(config: config, inputs: inputs)
        let warn = row(rows, id: "accuracy.parse_health.Battery Health")
        XCTAssertEqual(warn?.severity, .warn)
        XCTAssertTrue(warn?.detail.contains("20%") ?? false)
        // Skeleton of "ERR" is "xxx"; a raw value must never appear.
        XCTAssertTrue(warn?.detail.contains("xxx") ?? false)
        XCTAssertFalse(warn?.detail.contains("ERR") ?? true)
    }

    func testPercentageEAWithRawCountsGetsCountsHint() throws {
        let yaml = """
        custom_eas:
          - name: "Failures"
            column: "STIG Failures"
            type: percentage
        """
        let config = try makeConfig(yaml)
        // A raw-count column mis-typed percentage: >100 all-digit values fail the
        // 0–100 clamp, so the worst skeleton is all-9s → the counts hint fires.
        let good = ["10", "20"]
        let counts = ["420", "381", "512", "277", "633", "199", "808", "144"]
        let csv = ConfigDoctorService.AccuracyCSV(
            columns: ["STIG Failures"],
            rows: (good + counts).map { ["STIG Failures": $0] },
            ageDays: 0, fileName: "x.csv"
        )
        let inputs = ConfigDoctorService.AccuracyInputs(
            csv: csv, computersCount: nil, eaRows: nil, coverageDrift: nil
        )
        let rows = ConfigDoctorService.evaluateAccuracy(config: config, inputs: inputs)
        let warn = row(rows, id: "accuracy.parse_health.STIG Failures")
        XCTAssertEqual(warn?.severity, .warn)
        XCTAssertTrue(warn?.hint?.contains("raw counts") ?? false)
        XCTAssertTrue(warn?.hint?.contains("0–100") ?? false)
    }

    func testParseHealthGenericHintWhenNotPercentageCounts() throws {
        let yaml = """
        custom_eas:
          - name: "OSVer"
            column: "OS Version"
            type: version
        """
        let config = try makeConfig(yaml)
        let good = ["15.4", "14.7"]
        let bad = Array(repeating: "n/a", count: 8)
        let csv = ConfigDoctorService.AccuracyCSV(
            columns: ["OS Version"],
            rows: (good + bad).map { ["OS Version": $0] },
            ageDays: 0, fileName: "x.csv"
        )
        let inputs = ConfigDoctorService.AccuracyInputs(
            csv: csv, computersCount: nil, eaRows: nil, coverageDrift: nil
        )
        let rows = ConfigDoctorService.evaluateAccuracy(config: config, inputs: inputs)
        let warn = row(rows, id: "accuracy.parse_health.OS Version")
        XCTAssertEqual(warn?.severity, .warn)
        XCTAssertTrue(warn?.hint?.contains("Check the EA type") ?? false)
        XCTAssertFalse(warn?.hint?.contains("raw counts") ?? true)
    }

    func testParseHealthAggregatesCleanColumnsIntoOneOK() throws {
        let yaml = """
        custom_eas:
          - name: "OSVer"
            column: "OS Version"
            type: version
          - name: "State"
            column: "State"
            type: text
        """
        let config = try makeConfig(yaml)
        let csv = ConfigDoctorService.AccuracyCSV(
            columns: ["OS Version", "State"],
            rows: [
                ["OS Version": "15.4", "State": "Managed"],
                ["OS Version": "14.7.1", "State": "Managed"],
            ],
            ageDays: 0, fileName: "x.csv"
        )
        let inputs = ConfigDoctorService.AccuracyInputs(
            csv: csv, computersCount: nil, eaRows: nil, coverageDrift: nil
        )
        let rows = ConfigDoctorService.evaluateAccuracy(config: config, inputs: inputs)
        let ok = row(rows, id: "accuracy.parse_health.ok")
        XCTAssertEqual(ok?.severity, .pass)
        XCTAssertTrue(ok?.detail.contains("2 columns") ?? false)
        XCTAssertFalse(rows.contains { $0.id.hasPrefix("accuracy.parse_health.OS") })
    }

    func testParseHealthOnBaselineIntColumnFromEAResults() throws {
        let yaml = """
        compliance:
          enabled: true
          failures_count_column: "STIG Count"
          baseline_label: "STIG"
        """
        let config = try makeConfig(yaml)
        // 3 valid ints, 7 junk → 30% parse rate on the ea-results int column.
        var eaRows: [EAResultRow] = (1...3).map {
            EAResultRow(device: "d\($0)", eaName: "STIG Count", value: $0)
        }
        eaRows += (4...10).map {
            EAResultRow(device: "d\($0)", eaName: "STIG Count", stringValue: "N/A")
        }
        let inputs = ConfigDoctorService.AccuracyInputs(
            csv: nil, computersCount: nil, eaRows: eaRows, coverageDrift: nil
        )
        let rows = ConfigDoctorService.evaluateAccuracy(config: config, inputs: inputs)
        XCTAssertEqual(row(rows, id: "accuracy.parse_health.STIG Count")?.severity, .warn)
    }

    // MARK: - Accuracy: EA coverage drift (check 3)

    func testCoverageDriftFlagsBigDropsAndCaps() throws {
        let config = try makeConfig(cleanYAML)
        // 7 EAs each dropped 20 points → 5 warns + 1 "more" row.
        let drops = (1...7).map {
            EAParseHealthService.CoverageDrift(
                eaName: "EA\($0)", previousPct: 90, currentPct: 70
            )
        }
        let inputs = ConfigDoctorService.AccuracyInputs(
            csv: nil, computersCount: nil, eaRows: nil, coverageDrift: .computed(drops)
        )
        let rows = ConfigDoctorService.evaluateAccuracy(config: config, inputs: inputs)
        let driftWarns = rows.filter {
            $0.id.hasPrefix("accuracy.coverage_drift.") && $0.id != "accuracy.coverage_drift.more"
        }
        XCTAssertEqual(driftWarns.count, 5, "capped at 5 named EAs")
        let more = row(rows, id: "accuracy.coverage_drift.more")
        XCTAssertEqual(more?.severity, .warn)
        XCTAssertTrue(more?.detail.contains("+2 more") ?? false)
    }

    func testCoverageDriftStableEmitsOK() throws {
        let config = try makeConfig(cleanYAML)
        let stable = [
            EAParseHealthService.CoverageDrift(eaName: "EA1", previousPct: 90, currentPct: 89)
        ]
        let inputs = ConfigDoctorService.AccuracyInputs(
            csv: nil, computersCount: nil, eaRows: nil, coverageDrift: .computed(stable)
        )
        let rows = ConfigDoctorService.evaluateAccuracy(config: config, inputs: inputs)
        XCTAssertEqual(row(rows, id: "accuracy.coverage_drift.ok")?.severity, .pass)
    }

    func testCoverageDriftSkippedWhenNoDriftData() throws {
        let config = try makeConfig(cleanYAML)
        let inputs = ConfigDoctorService.AccuracyInputs(
            csv: nil, computersCount: nil, eaRows: nil, coverageDrift: nil
        )
        let rows = ConfigDoctorService.evaluateAccuracy(config: config, inputs: inputs)
        XCTAssertFalse(rows.contains { $0.id.hasPrefix("accuracy.coverage_drift") },
                       "no gathered coverageDrift input at all means no drift rows")
    }

    /// S3 (security review): insufficient data must render distinctly from a
    /// computed-and-stable result — never the green "EA coverage stable" row.
    func testCoverageDriftInsufficientDataRendersDistinctSuggestRow() throws {
        let config = try makeConfig(cleanYAML)
        let inputs = ConfigDoctorService.AccuracyInputs(
            csv: nil, computersCount: nil, eaRows: nil,
            coverageDrift: .insufficientData(reason: "Fewer than two ea-results snapshots")
        )
        let rows = ConfigDoctorService.evaluateAccuracy(config: config, inputs: inputs)
        let unavailable = row(rows, id: "accuracy.coverage_drift.unavailable")
        XCTAssertEqual(unavailable?.severity, .suggest)
        XCTAssertTrue(unavailable?.detail.contains("Fewer than two") ?? false)
        XCTAssertNil(row(rows, id: "accuracy.coverage_drift.ok"),
                     "insufficient data must never render as the stable OK row")
    }

    /// S3: when the reason names a salvage, that reason text must surface in
    /// the row detail (not be swallowed into a generic message).
    func testCoverageDriftInsufficientDataWithSalvageReasonSurfacesIt() throws {
        let config = try makeConfig(cleanYAML)
        let salvageReason = "The most recent snapshot(s) were salvaged from truncated files — "
            + "coverage change can't be verified"
        let inputs = ConfigDoctorService.AccuracyInputs(
            csv: nil, computersCount: nil, eaRows: nil,
            coverageDrift: .insufficientData(reason: salvageReason)
        )
        let rows = ConfigDoctorService.evaluateAccuracy(config: config, inputs: inputs)
        let unavailable = row(rows, id: "accuracy.coverage_drift.unavailable")
        XCTAssertEqual(unavailable?.severity, .suggest)
        XCTAssertTrue(unavailable?.detail.contains("salvaged") ?? false)
    }

    /// S3: `.computed([])` (a real drift computation that found no drops) must
    /// still render the green stable row — only `.insufficientData` changes.
    func testCoverageDriftComputedEmptyStillEmitsOK() throws {
        let config = try makeConfig(cleanYAML)
        let inputs = ConfigDoctorService.AccuracyInputs(
            csv: nil, computersCount: nil, eaRows: nil, coverageDrift: .computed([])
        )
        let rows = ConfigDoctorService.evaluateAccuracy(config: config, inputs: inputs)
        XCTAssertEqual(row(rows, id: "accuracy.coverage_drift.ok")?.severity, .pass)
        XCTAssertNil(row(rows, id: "accuracy.coverage_drift.unavailable"))
    }

    // MARK: - Accuracy: mSCP count-vs-list cross-check (check 4)

    func testCrossCheckWarnsOnDisagreement() throws {
        let yaml = """
        compliance:
          enabled: true
          failures_count_column: "STIG Count"
          failures_list_column: "STIG List"
          baseline_label: "STIG"
        """
        let config = try makeConfig(yaml)
        // 10 devices: 9 disagree (count 5 vs list length 1) → 90% > 5%.
        var eaRows: [EAResultRow] = []
        for i in 1...10 {
            eaRows.append(EAResultRow(device: "d\(i)", eaName: "STIG Count", value: 5))
            let list = i == 1 ? "a|b|c|d|e" : "a"  // d1 agrees (5), rest disagree
            eaRows.append(EAResultRow(device: "d\(i)", eaName: "STIG List", stringValue: list))
        }
        let inputs = ConfigDoctorService.AccuracyInputs(
            csv: nil, computersCount: nil, eaRows: eaRows, coverageDrift: nil
        )
        let rows = ConfigDoctorService.evaluateAccuracy(config: config, inputs: inputs)
        let cc = row(rows, id: "accuracy.cross_check.STIG")
        XCTAssertEqual(cc?.severity, .warn)
        XCTAssertTrue(cc?.detail.contains("10") ?? false, "names devices compared")
    }

    func testCrossCheckPassesWhenCountsAgree() throws {
        let yaml = """
        compliance:
          enabled: true
          failures_count_column: "STIG Count"
          failures_list_column: "STIG List"
          baseline_label: "STIG"
        """
        let config = try makeConfig(yaml)
        let eaRows: [EAResultRow] = [
            EAResultRow(device: "d1", eaName: "STIG Count", value: 2),
            EAResultRow(device: "d1", eaName: "STIG List", stringValue: "a|b"),
            EAResultRow(device: "d2", eaName: "STIG Count", value: 0),
            EAResultRow(device: "d2", eaName: "STIG List", stringValue: ""),
        ]
        let inputs = ConfigDoctorService.AccuracyInputs(
            csv: nil, computersCount: nil, eaRows: eaRows, coverageDrift: nil
        )
        let rows = ConfigDoctorService.evaluateAccuracy(config: config, inputs: inputs)
        XCTAssertEqual(row(rows, id: "accuracy.cross_check.STIG")?.severity, .pass)
    }

    func testCrossCheckSkippedWhenNoListColumn() throws {
        let yaml = """
        compliance:
          enabled: true
          failures_count_column: "STIG Count"
          baseline_label: "STIG"
        """
        let config = try makeConfig(yaml)
        let eaRows = [EAResultRow(device: "d1", eaName: "STIG Count", value: 0)]
        let inputs = ConfigDoctorService.AccuracyInputs(
            csv: nil, computersCount: nil, eaRows: eaRows, coverageDrift: nil
        )
        let rows = ConfigDoctorService.evaluateAccuracy(config: config, inputs: inputs)
        XCTAssertFalse(rows.contains { $0.id.hasPrefix("accuracy.cross_check") },
                       "no failures_list_column means no cross-check row")
    }

    // MARK: - Alerts (2.6 metric-threshold alerting)

    func testAlertRuleWithUnknownMetricEmitsErrorRow() throws {
        let yaml = """
        alerts:
          enabled: true
          rules:
            - metric: "filevault_percent"
              when: "below"
              threshold: 90
        """
        let config = try makeConfig(yaml)
        let rows = ConfigDoctorService.evaluate(
            config: config, parseError: nil, csvHeaders: nil,
            csvFamily: nil, eaCoverageNames: []
        )
        let rule = row(rows, id: "alerts.rule.0")
        XCTAssertEqual(rule?.severity, .fail)
        XCTAssertTrue(rule?.detail.contains("filevault_percent") ?? false)
        XCTAssertTrue(rule?.detail.contains("unknown metric") ?? false)
    }

    func testAlertsEnabledWithoutUsableNotifyWarns() throws {
        let yaml = """
        alerts:
          enabled: true
          rules:
            - metric: "filevault_pct"
              when: "below"
              threshold: 90
        """
        let config = try makeConfig(yaml)
        let rows = ConfigDoctorService.evaluate(
            config: config, parseError: nil, csvHeaders: nil,
            csvFamily: nil, eaCoverageNames: []
        )
        XCTAssertEqual(row(rows, id: "alerts.notify_missing")?.severity, .warn)
        XCTAssertNil(row(rows, id: "alerts.armed"), "not armed without a usable webhook")
    }

    func testAlertsEnabledWithUsableNotifyAndValidRuleEmitsArmedOK() throws {
        let yaml = """
        alerts:
          enabled: true
          rules:
            - metric: "filevault_pct"
              when: "below"
              threshold: 90
        notify:
          enabled: true
          url: "https://hooks.example.com/webhook"
        """
        let config = try makeConfig(yaml)
        let rows = ConfigDoctorService.evaluate(
            config: config, parseError: nil, csvHeaders: nil,
            csvFamily: nil, eaCoverageNames: []
        )
        let armed = row(rows, id: "alerts.armed")
        XCTAssertEqual(armed?.severity, .pass)
        XCTAssertTrue(armed?.detail.contains("1 alert rule") ?? false)
        XCTAssertNil(row(rows, id: "alerts.notify_missing"))
    }

    func testNoAlertsBlockEmitsNoAlertsRows() throws {
        let config = try makeConfig(cleanYAML)
        let rows = ConfigDoctorService.evaluate(
            config: config, parseError: nil, csvHeaders: cleanHeaders,
            csvFamily: .computers, eaCoverageNames: []
        )
        XCTAssertFalse(rows.contains { $0.id.hasPrefix("alerts.") },
                       "a workspace that never opted into alerts gets no alerts rows")
    }

    // MARK: - Unknown keys

    func testUnknownKeysBecomeWarningRowsThatNameTheKeyPath() {
        let rows = ConfigDoctorService.unknownKeyRows([
            UnknownKey(keyPath: "output.keep_lastest_runs", suggestion: "keep_latest_runs"),
            UnknownKey(keyPath: "exceptions[0].expires", suggestion: nil),
        ])
        XCTAssertEqual(rows.map(\.id), ["config.unknown_key.0", "config.unknown_key.1"])
        XCTAssertEqual(rows.map(\.severity), [.warn, .warn],
                       "a typo must not be able to turn a scheduled run red")
        XCTAssertEqual(rows.map(\.title), ["output.keep_lastest_runs", "exceptions[0].expires"])
        XCTAssertEqual(rows.first?.detail,
                       "The app does not read this key. Did you mean \"keep_latest_runs\"?")
        XCTAssertEqual(rows.last?.detail, "The app does not read this key.")
        XCTAssertNotNil(rows.last?.hint)
    }

    func testMoreThanTwentyUnknownKeysEndInOneRowSayingHowManyMore() {
        let keys = (0..<23).map { UnknownKey(keyPath: "extra_\($0)", suggestion: nil) }
        let rows = ConfigDoctorService.unknownKeyRows(keys)
        XCTAssertEqual(rows.count, 21)
        XCTAssertEqual(rows.prefix(20).map(\.title), keys.prefix(20).map(\.keyPath))
        XCTAssertEqual(rows.last?.id, "config.unknown_key.more")
        XCTAssertEqual(rows.last?.severity, .warn)
        XCTAssertEqual(rows.last?.detail, "3 more keys in config.yaml that the app does not read.")
        XCTAssertEqual(ConfigDoctorService.unknownKeyRows(Array(keys.prefix(21))).last?.detail,
                       "1 more key in config.yaml that the app does not read.")
        XCTAssertEqual(ConfigDoctorService.unknownKeyRows(Array(keys.prefix(20))).count, 20)
    }

    func testUnknownKeyRowsReadTheWorkspaceConfigAndNeverShowAValue() throws {
        let yaml = """
        notify:
          enabled: false
          webhook_url: "https://hooks.example.com/services/T000/B000/abc123"
        thresholds:
          stale_device_dayz: 45
        """
        try withWorkspace(yaml) { profile, _ in
            let rows = ConfigDoctorService.unknownKeyRows(profile: profile)
            XCTAssertEqual(rows.map(\.title),
                           ["notify.webhook_url", "thresholds.stale_device_dayz"])
            XCTAssertEqual(rows.last?.detail,
                           "The app does not read this key. Did you mean \"stale_device_days\"?")
            let shown = rows.map { $0.title + $0.detail + ($0.hint ?? "") }.joined()
            XCTAssertFalse(shown.contains("hooks.example.com"))
            XCTAssertFalse(shown.contains("45"))
        }
    }

    /// Keys 2.9 stopped reading: an older build wrote some of them itself. The file still loads
    /// and each shows up once, as a suggestion of its own (never a warning or failure), apart
    /// from a genuinely unknown key, which stays a warning. No value is shown.
    func testRetiredKeysGetTheirOwnSuggestionAndAreNotAlsoReportedAsUnknown() throws {
        let yaml = """
        jamf_cli:
          enabled: false
          data_dir: jamf-cli-data
          allow_live_overview: false
        platform:
          enabled: true
          compliance_benchmarks: [CIS]
        thresholds:
          checkin_overdue_days: 14
          profile_error_critical: 80
          stale_device_dayz: 45
        charts:
          os_adoption:
            enabled: false
            per_major_charts: true
        branding:
          accent_color: "#112233"
          accent_dark: "#445566"
        """
        let config = try makeConfig(yaml)
        XCTAssertEqual(config.thresholds?.resolvedCheckinOverdueDays, 14)
        XCTAssertEqual(config.branding?.accentColor, "#112233")
        XCTAssertEqual(config.platform?.benchmarkTitles, ["CIS"])

        try withWorkspace(yaml) { profile, _ in
            let rows = ConfigDoctorService.unknownKeyRows(profile: profile)
            let unknown = rows.filter { $0.id.hasPrefix("config.unknown_key.") }
            XCTAssertEqual(unknown.map(\.title), ["thresholds.stale_device_dayz"])
            XCTAssertEqual(unknown.first?.id, "config.unknown_key.0")
            XCTAssertEqual(unknown.first?.severity, .warn)
            XCTAssertEqual(unknown.first?.detail,
                           "The app does not read this key. Did you mean \"stale_device_days\"?")

            let retired = rows.filter { $0.id.hasPrefix("config.retired_key.") }
            XCTAssertEqual(retired.map(\.title), [
                "branding.accent_dark", "charts.os_adoption.enabled",
                "jamf_cli.allow_live_overview", "jamf_cli.enabled", "platform.enabled",
                "thresholds.profile_error_critical",
            ])
            XCTAssertEqual(retired.map(\.id), (0..<6).map { "config.retired_key.\($0)" })
            XCTAssertEqual(Set(retired.map(\.severity)), [.suggest])
            XCTAssertEqual(Set(retired.map(\.detail)), ["No longer read since 2.9."])
            XCTAssertEqual(retired.map(\.hint), [
                "The next Config save removes it.", "The next Customize Apply removes it.",
                "The next Config save removes it.", "The next Config save removes it.",
                "The next Config save removes it.", "The next Config save removes it.",
            ])
            XCTAssertEqual(rows.count, unknown.count + retired.count, "each key is reported once")
            XCTAssertFalse(rows.map(\.detail).joined().contains("445566"))
        }
    }

    /// A retired key in a block no app writer rewrites is the user's to delete.
    func testARetiredKeyNoSaveRemovesTellsTheUserToDeleteTheLine() {
        let rows = ConfigDoctorService.unknownKeyRows([
            UnknownKey(keyPath: "html.old_switch", suggestion: nil, retiredSince: "2.9"),
        ])
        XCTAssertEqual(rows.map(\.hint), ["Delete the line from config.yaml."])
        XCTAssertEqual(rows.map(\.severity), [.suggest])
    }

    func testUnknownKeyRowsStillNameTheTypoWhenTheFileDoesNotDecode() throws {
        let yaml = """
        custom_eas:
          - name: "Disk Use"
            colum: "Boot Drive Percentage Full"
            type: percentage
        """
        XCTAssertThrowsError(try makeConfig(yaml), "`column` is required")
        try withWorkspace(yaml) { profile, _ in
            XCTAssertEqual(ConfigDoctorService.unknownKeyRows(profile: profile).map(\.detail),
                           ["The app does not read this key. Did you mean \"column\"?"])
        }
    }

    // MARK: - Security policy (hand-typed values)

    func testSecurityPolicyIssuesBecomeWarningRows() {
        let issues = [
            SecurityPolicyIssue(keyPath: "security_policy.controls.sip", value: "wrn",
                                used: "fail"),
            SecurityPolicyIssue(keyPath: "security_policy.controls.gatekeeper", value: "",
                                used: "fail"),
        ]
        let rows = ConfigDoctorService.securityPolicyRows(
            issues: issues, policy: .default, hardware: [:])
        XCTAssertEqual(rows.map(\.severity), [.warn, .warn],
                       "a typo must not be able to turn a scheduled run red")
        XCTAssertEqual(rows.map(\.title),
                       ["security_policy.controls.sip", "security_policy.controls.gatekeeper"])
        XCTAssertEqual(rows[0].detail, "\"wrn\" is not fail, warning or ignore — using fail")
        XCTAssertEqual(Set(rows.map(\.id)).count, 2, "the audit list keys its rows by id")
    }

    func testAnUnknownSecurityPolicyKeyIsLeftToTheUnknownKeyRows() {
        let rows = ConfigDoctorService.securityPolicyRows(
            issues: [SecurityPolicyIssue(keyPath: "security_policy.mode", value: "",
                                         used: "")],
            policy: .default, hardware: [:])
        XCTAssertEqual(rows, [], "unknownKeyRows reports it, with every other block's")
    }

    func testAHardwareLevelIssueSaysItUsesTheFileVaultLevel() {
        let rows = ConfigDoctorService.securityPolicyRows(
            issues: [SecurityPolicyIssue(
                keyPath: "security_policy.filevault_off_hardware_encrypted", value: "maybe",
                used: "the FileVault level")],
            policy: .default, hardware: [:])
        XCTAssertEqual(rows.first?.detail,
                       "\"maybe\" is not fail, warning or ignore — using the FileVault level")
    }

    func testABlockOfTheWrongShapeIsNotCalledALevel() {
        let rows = ConfigDoctorService.securityPolicyRows(
            issues: [SecurityPolicyIssue(keyPath: "security_policy.controls", value: "strict",
                                         used: "fail for every control")],
            policy: .default, hardware: [:])
        XCTAssertEqual(rows.first?.severity, .warn)
        XCTAssertEqual(rows.first?.detail, "Expected a block of settings, found \"strict\" "
            + "— using fail for every control")
    }

    func testAVocabularyValueThatIsNotTextWarnsAndIsSkipped() {
        let rows = ConfigDoctorService.securityPolicyRows(
            issues: [
                SecurityPolicyIssue(keyPath: "security_policy.on_values.firewall", value: "7",
                                    used: "skipped"),
                SecurityPolicyIssue(keyPath: "security_policy.off_values.sip", value: "{…}",
                                    used: "skipped"),
            ], policy: .default, hardware: [:])
        XCTAssertEqual(rows.map(\.severity), [.warn, .warn])
        XCTAssertEqual(rows.map(\.title), [
            "security_policy.on_values.firewall", "security_policy.off_values.sip",
        ])
        XCTAssertEqual(rows[0].detail, "\"7\" in on_values is not text — skipped")
        XCTAssertEqual(rows[1].detail, "\"{…}\" in off_values is not text — skipped")
        XCTAssertEqual(rows[0].hint,
                       "Write each value as text, such as \"Pass\" (quote a number), or remove it.")
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)
    }

    func testAnEmptyVocabularyValueWarnsAndIsSkipped() {
        let rows = ConfigDoctorService.securityPolicyRows(
            issues: [SecurityPolicyIssue(
                keyPath: "security_policy.on_values.gatekeeper", value: "", used: "skipped")],
            policy: .default, hardware: [:])
        XCTAssertEqual(rows.first?.severity, .warn)
        XCTAssertEqual(rows.first?.detail, "An empty value in on_values is skipped")
    }

    func testAValueInBothVocabularyListsWarnsThatItReadsOff() {
        let rows = ConfigDoctorService.securityPolicyRows(
            issues: [SecurityPolicyIssue(
                keyPath: "security_policy.on_values.firewall", value: "Pass", used: "off")],
            policy: .default, hardware: [:])
        XCTAssertEqual(rows.first?.severity, .warn)
        XCTAssertEqual(rows.first?.detail,
                       "\"Pass\" is listed in both on_values and off_values — reading it as off")
        XCTAssertEqual(rows.first?.hint,
                       "Remove it from on_values, or from off_values, in config.yaml.")
    }

    func testAVocabularyBlockOfTheWrongShapeIsNotCalledAValue() {
        let rows = ConfigDoctorService.securityPolicyRows(
            issues: [SecurityPolicyIssue(
                keyPath: "security_policy.off_values", value: "Fail",
                used: "the built-in values only")],
            policy: .default, hardware: [:])
        XCTAssertEqual(rows.first?.detail, "Expected a block of settings, found \"Fail\" "
            + "— using the built-in values only")
    }

    func testNoSecurityPolicyIssuesEmitNoRows() {
        XCTAssertEqual(ConfigDoctorService.securityPolicyRows(
            issues: [], policy: .default, hardware: [:]), [])
        XCTAssertEqual(ConfigDoctorService.securityPolicyRows(
            issues: [], policy: SecurityControlPolicy(sip: .warning), hardware: ["s:C02": true]),
                       [])
    }

    func testTheHardwareRuleWithoutHardwareFactsWarnsOnce() {
        let policy = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .warning)
        let rows = ConfigDoctorService.securityPolicyRows(
            issues: [], policy: policy, hardware: [:])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.severity, .warn)
        XCTAssertEqual(rows.first?.title, "security_policy.filevault_off_hardware_encrypted")
        XCTAssertEqual(rows.first?.detail, "No hardware information yet — the rule applies "
            + "after an inventory collect. Until then FileVault off counts at the FileVault "
            + "level.")
    }

    func testTheHardwareRuleWithHardwareFactsOrNoRuleEmitsNoRow() {
        let rule = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .ignore)
        XCTAssertEqual(ConfigDoctorService.securityPolicyRows(
            issues: [], policy: rule, hardware: ["s:C02": false]), [], "facts present")
        XCTAssertEqual(ConfigDoctorService.securityPolicyRows(
            issues: [], policy: .default, hardware: [:]), [], "no rule")
        XCTAssertEqual(ConfigDoctorService.securityPolicyRows(
            issues: [], policy: SecurityControlPolicy(
                fileVault: .ignore, fileVaultOffHardwareEncrypted: .warning), hardware: [:]),
                       [], "FileVault is ignored, so the rule is not in use")
    }

    // MARK: CSV hardware columns

    private let hardwareRule = "security_policy:\n  filevault_off_hardware_encrypted: warning\n"
    private let jamfHeaders = ["Computer Name", "Model", "Model Identifier", "Architecture Type"]

    private func csvHardwareRows(
        _ yaml: String, headers: [String]? = nil, family: CSVFamily? = .computers
    ) throws -> [DoctorRow] {
        ConfigDoctorService.csvHardwareColumnRows(
            config: try makeConfig(yaml), csvHeaders: headers ?? jamfHeaders, csvFamily: family)
    }

    /// `columns.model` is the marketing name, so mapping it does not satisfy the rule.
    func testTheHardwareRuleOnACSVNamesTheUnmappedModelIdentifier() throws {
        let rows = try csvHardwareRows(hardwareRule
            + "columns:\n  model: Model\n  architecture: Architecture Type\n")
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.severity, .warn)
        XCTAssertEqual(row.id, "security_policy.csv_hardware_columns")
        XCTAssertEqual(row.title, "security_policy.filevault_off_hardware_encrypted")
        XCTAssertEqual(row.detail, "columns.model_identifier is not mapped, so a CSV report "
            + "cannot tell which Macs are hardware-encrypted. FileVault off counts at the "
            + "FileVault level for them.")
        XCTAssertEqual(row.hint, "Map it in Config, or re-run scaffold, to the export's "
            + "'Model Identifier' column.")
    }

    func testTheHardwareRuleOnACSVNamesEveryUnmappedHardwareColumn() throws {
        let rows = try csvHardwareRows(hardwareRule + "columns:\n  computer_name: Computer Name\n")
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].detail.hasPrefix(
            "columns.model_identifier and columns.architecture are not mapped"))
        XCTAssertTrue(rows[0].hint?.contains("'Model Identifier' and 'Architecture Type'") ?? false)
        XCTAssertEqual(try csvHardwareRows(hardwareRule).count, 1, "no columns block at all")
    }

    func testNoCSVHardwareRowWhenBothColumnsAreMappedOrTheRuleIsNotInUse() throws {
        let mapped = "columns:\n  model_identifier: Model Identifier\n"
            + "  architecture: Architecture Type\n"
        XCTAssertEqual(try csvHardwareRows(hardwareRule + mapped), [], "both mapped")
        XCTAssertEqual(try csvHardwareRows("columns:\n  model: Model\n"), [], "no rule")
        XCTAssertEqual(try csvHardwareRows(
            "security_policy:\n  controls:\n    filevault: ignore\n"
                + "  filevault_off_hardware_encrypted: warning\n"), [], "FileVault is ignored")
    }

    func testNoCSVHardwareRowWithoutAComputerCSV() throws {
        XCTAssertEqual(ConfigDoctorService.csvHardwareColumnRows(
            config: try makeConfig(hardwareRule), csvHeaders: nil, csvFamily: nil), [],
            "no CSV: the computers snapshot decides, and its own row covers that")
        XCTAssertEqual(try csvHardwareRows(hardwareRule, family: .mobile), [], "mobile export")
    }

    /// `run` passes the newest CSV's headers and family through.
    func testRunReportsTheUnmappedHardwareColumnsOfTheWorkspaceCSV() throws {
        let yaml = hardwareRule + "columns:\n  computer_name: Computer Name\n"
        try withWorkspace(yaml) { profile, workspace in
            try (jamfHeaders.joined(separator: ",") + "\nMac-1,Model,Mac1,arm64\n")
                .write(to: workspace.appendingPathComponent("export.csv"),
                       atomically: true, encoding: .utf8)
            let ids = ConfigDoctorService.run(profile: profile).rows.map(\.id)
            XCTAssertEqual(ids.filter { $0 == "security_policy.csv_hardware_columns" }.count, 1)
        }
    }

    // MARK: Security policy rows read from a workspace

    private func withWorkspace(_ yaml: String, body: (String, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-doctor-policy-\(UUID().uuidString)", isDirectory: true)
        let profile = "doctor-policy"
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try yaml.write(to: workspace.appendingPathComponent("config.yaml"),
                       atomically: true, encoding: .utf8)
        let saved = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            if let saved { setenv("JRC_TEST_WORKSPACES_ROOT", saved, 1) }
            else { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        try body(profile, workspace)
    }

    func testSecurityPolicyRowsReadTheWorkspaceConfig() throws {
        let yaml = """
        security_policy:
          controls:
            sip: wrn
          antivirus: warning
        """
        try withWorkspace(yaml) { profile, _ in
            let rows = ConfigDoctorService.securityPolicyRows(
                profile: profile, config: try makeConfig(yaml))
            XCTAssertEqual(rows.map(\.title), ["security_policy.controls.sip"])
            XCTAssertEqual(rows.map(\.severity), [.warn])
            let doctor = rows + ConfigDoctorService.unknownKeyRows(profile: profile)
            XCTAssertEqual(doctor.filter { $0.title == "security_policy.antivirus" }.count, 1,
                           "an unknown key is reported once")
        }
    }

    /// Every kind of vocabulary issue in one file reaches the Doctor from the loader, as
    /// warnings: a number, an empty value, a value in both lists, and an unknown control that
    /// is left to the unknown-key rows.
    func testSecurityPolicyRowsReportTheVocabularyIssuesInTheFile() throws {
        let yaml = """
        security_policy:
          on_values:
            firewall:
              - Pass
              - 7
              - ""
            sip: Protected
            bootstrap_token: Escrowed
          off_values:
            firewall: [Fail, pass]
            sip: Open
        """
        try withWorkspace(yaml) { profile, _ in
            let rows = ConfigDoctorService.securityPolicyRows(
                profile: profile, config: try makeConfig(yaml))
            XCTAssertEqual(rows.map(\.severity), [.warn, .warn, .warn])
            XCTAssertEqual(rows.map(\.title), [
                "security_policy.on_values.firewall", "security_policy.on_values.firewall",
                "security_policy.on_values.firewall",
            ])
            XCTAssertEqual(rows.map(\.detail), [
                "\"Pass\" is listed in both on_values and off_values — reading it as off",
                "\"7\" in on_values is not text — skipped",
                "An empty value in on_values is skipped",
            ])
            XCTAssertEqual(Set(rows.map(\.id)).count, 3)
            let unknown = ConfigDoctorService.unknownKeyRows(profile: profile)
            XCTAssertEqual(unknown.map(\.title), ["security_policy.on_values.bootstrap_token"])
        }
    }

    func testSecurityPolicyRowsAreSilentForAReadableVocabulary() throws {
        let yaml = """
        security_policy:
          on_values:
            firewall: ["Pass", "Compliant"]
          off_values:
            firewall: ["Fail", "Non-Compliant"]
        """
        try withWorkspace(yaml) { profile, _ in
            XCTAssertEqual(ConfigDoctorService.securityPolicyRows(
                profile: profile, config: try makeConfig(yaml)), [])
            XCTAssertEqual(ConfigDoctorService.unknownKeyRows(profile: profile), [])
        }
    }

    func testSecurityPolicyRowsReadTheComputersSnapshotForTheHardwareRule() throws {
        let yaml = "security_policy:\n  filevault_off_hardware_encrypted: warn\n"
        try withWorkspace(yaml) { profile, workspace in
            let config = try makeConfig(yaml)
            XCTAssertEqual(
                ConfigDoctorService.securityPolicyRows(profile: profile, config: config)
                    .map(\.title),
                ["security_policy.filevault_off_hardware_encrypted"],
                "the rule is set and there is no computers snapshot yet")

            let dir = workspace.appendingPathComponent("jamf-cli-data/computers",
                                                       isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Shape: Jamf Pro API computer inventory, `--section GENERAL,HARDWARE`.
            let computers = """
            [{"general": {"name": "mac-1"},
              "hardware": {"serialNumber": "C02ABC", "appleSilicon": true}}]
            """
            try computers.write(to: dir.appendingPathComponent("computers_20261001T090000.json"),
                                atomically: true, encoding: .utf8)
            XCTAssertEqual(
                ConfigDoctorService.securityPolicyRows(profile: profile, config: config), [],
                "the snapshot carries hardware facts")
        }
    }
}

// MARK: - EAResultRow test fixtures

private extension EAResultRow {
    init(device: String, eaName: String, value: Int) {
        self.init(
            computerId: nil, computerName: nil, serial: nil, eaId: nil,
            eaName: eaName, device: device, value: AnyCodable(value)
        )
    }

    init(device: String, eaName: String, stringValue: String) {
        self.init(
            computerId: nil, computerName: nil, serial: nil, eaId: nil,
            eaName: eaName, device: device, value: AnyCodable(stringValue)
        )
    }
}
