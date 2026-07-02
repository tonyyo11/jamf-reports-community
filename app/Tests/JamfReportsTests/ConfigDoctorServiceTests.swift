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

    // MARK: - platform

    func testPlatformEnabledWithoutBenchmarksWarns() throws {
        let yaml = """
        platform:
          enabled: true
          compliance_benchmarks: []
        """
        let config = try makeConfig(yaml)
        let rows = ConfigDoctorService.evaluate(
            config: config, parseError: nil, csvHeaders: nil,
            csvFamily: nil, eaCoverageNames: []
        )
        XCTAssertEqual(row(rows, id: "platform.benchmarks")?.severity, .warn)
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
            csv: nil, computersCount: nil, eaRows: nil, coverageDrift: drops
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
            csv: nil, computersCount: nil, eaRows: nil, coverageDrift: stable
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
                       "fewer than two snapshot days means no drift rows at all")
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
