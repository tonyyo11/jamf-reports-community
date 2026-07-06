import Foundation
import XCTest
@testable import JamfReports

// MARK: - Synthetic fixture helpers

private extension EAResultRow {
    /// Convenience init for test fixtures — matches the prod "device" shape.
    init(device: String, eaName: String, value: Int) {
        self.init(
            computerId: nil,
            computerName: nil,
            serial: nil,
            eaId: nil,
            eaName: eaName,
            device: device,
            value: AnyCodable(value)
        )
    }

    /// Convenience init for the legacy "computer_id" shape.
    init(computerId: String, eaName: String, value: Int) {
        self.init(
            computerId: computerId,
            computerName: nil,
            serial: nil,
            eaId: nil,
            eaName: eaName,
            device: nil,
            value: AnyCodable(value)
        )
    }

    /// Convenience init for a string-valued cell (e.g. a pipe-delimited list).
    init(device: String, eaName: String, stringValue: String) {
        self.init(
            computerId: nil,
            computerName: nil,
            serial: nil,
            eaId: nil,
            eaName: eaName,
            device: device,
            value: AnyCodable(stringValue)
        )
    }
}

// MARK: - Fixtures

private let stig = "Compliance - Failed mSCP Results Count - DISA STIG"
private let nist = "Compliance - Failed mSCP Results Count - NIST 800-53r5 Audit"
private let tailored  = "Compliance - Failed mSCP Results Count - Org Tailored Baseline"
private let stigList = "Compliance - Failed mSCP Result List - DISA STIG"

/// Synthetic ea-results fixture with fabricated device identifiers.
/// Shape uses the prod `device` field (no computer_id / serial).
/// Counts are chosen to exercise every band + No Data.
private func makeRows() -> [EAResultRow] {
    [
        // STIG failures: 5 devices
        .init(device: "mac-001", eaName: stig, value: 0),   // Pass
        .init(device: "mac-002", eaName: stig, value: 5),   // Low
        .init(device: "mac-003", eaName: stig, value: 20),  // Med-Low
        .init(device: "mac-004", eaName: stig, value: 35),  // Medium
        .init(device: "mac-005", eaName: stig, value: 60),  // High
        // mac-006 absent from STIG → No Data for STIG baseline

        // NIST failures: 4 devices (mac-001..004; mac-005 + mac-006 absent)
        .init(device: "mac-001", eaName: nist, value: 0),
        .init(device: "mac-002", eaName: nist, value: 3),
        .init(device: "mac-003", eaName: nist, value: 0),
        .init(device: "mac-004", eaName: nist, value: 45),

        // mac-006 only has a NIST row to ensure it appears in the universe
        .init(device: "mac-006", eaName: nist, value: 0),
    ]
}

private func makeBaseline(_ col: String, name: String = "test") -> ComplianceBaselineConfig {
    ComplianceBaselineConfig(name: name, failuresCountColumn: col, ruleCount: nil)
}

// MARK: - Tests

final class MSCPComplianceServiceTests: XCTestCase {

    // MARK: Band counts

    func testStigBandCountsCorrect() {
        let rows = makeRows()
        let results = MSCPComplianceService.evaluate(rows: rows, baselines: [makeBaseline(stig)])
        let r = try! XCTUnwrap(results.first)

        let byLabel = Dictionary(uniqueKeysWithValues: r.bands.map { ($0.label, $0.count) })
        // Universe = 6 devices; STIG rows exist for mac-001…005 only.
        XCTAssertEqual(byLabel["Pass"],    1)
        XCTAssertEqual(byLabel["Low"],     1)
        XCTAssertEqual(byLabel["Med-Low"], 1)
        XCTAssertEqual(byLabel["Medium"],  1)
        XCTAssertEqual(byLabel["High"],    1)
        XCTAssertEqual(byLabel["No Data"], 1, "mac-006 has no STIG row → No Data")
    }

    func testNistBandCountsCorrect() {
        let rows = makeRows()
        let results = MSCPComplianceService.evaluate(rows: rows, baselines: [makeBaseline(nist)])
        let r = try! XCTUnwrap(results.first)

        let byLabel = Dictionary(uniqueKeysWithValues: r.bands.map { ($0.label, $0.count) })
        // Universe = 6 devices; NIST rows for mac-001..004 + mac-006 (5 devices).
        // mac-005 has only a STIG row — no NIST row → No Data.
        XCTAssertEqual(byLabel["Pass"],   3)   // mac-001, mac-003, mac-006
        XCTAssertEqual(byLabel["Low"],    1)   // mac-002
        XCTAssertEqual(byLabel["Medium"], 1)   // mac-004
        XCTAssertEqual(byLabel["No Data"], 1)  // mac-005 absent from NIST
    }

    // MARK: No-Data count

    func testNoDataCountMatchesAbsentDevices() {
        let rows = makeRows()
        let results = MSCPComplianceService.evaluate(rows: rows, baselines: [makeBaseline(stig)])
        let r = try! XCTUnwrap(results.first)
        // mac-006 has no STIG row
        XCTAssertEqual(r.noDataCount, 1)
    }

    // MARK: compliancePct definition (Pass ÷ devicesWithData)

    func testStigCompliancePctPassOverDevicesWithData() {
        let rows = makeRows()
        let results = MSCPComplianceService.evaluate(rows: rows, baselines: [makeBaseline(stig)])
        let r = try! XCTUnwrap(results.first)

        // devicesWithData = 5 (mac-001..005); pass = 1 (mac-001)
        let expected = (1.0 / 5.0) * 100.0
        let actual = try! XCTUnwrap(r.compliancePct)
        XCTAssertEqual(actual, expected, accuracy: 0.01)
    }

    func testNistCompliancePctPassOverDevicesWithData() {
        let rows = makeRows()
        let results = MSCPComplianceService.evaluate(rows: rows, baselines: [makeBaseline(nist)])
        let r = try! XCTUnwrap(results.first)

        // devicesWithData = 5 (mac-001..004 + mac-006; mac-005 is No Data)
        // pass = 3 (mac-001, mac-003, mac-006)
        let expected = (3.0 / 5.0) * 100.0
        let actual = try! XCTUnwrap(r.compliancePct)
        XCTAssertEqual(actual, expected, accuracy: 0.01)
    }

    // MARK: Multi-baseline

    func testMultiBaselineReturnsOneResultPerBaseline() {
        let rows = makeRows()
        let baselines = [makeBaseline(stig, name: "STIG"), makeBaseline(nist, name: "NIST")]
        let results = MSCPComplianceService.evaluate(rows: rows, baselines: baselines)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].name, "STIG")
        XCTAssertEqual(results[1].name, "NIST")
    }

    func testMultiBaselinePreservesOrder() {
        let rows = makeRows()
        let baselines = [
            makeBaseline(tailored, name: "Tailored"),
            makeBaseline(stig, name: "STIG"),
            makeBaseline(nist, name: "NIST"),
        ]
        let results = MSCPComplianceService.evaluate(rows: rows, baselines: baselines)
        XCTAssertEqual(results.map(\.name), ["Tailored", "STIG", "NIST"])
    }

    // MARK: Empty ea-results → nil compliancePct → proxy fallback

    func testEmptyRowsProducesNilCompliancePct() {
        let results = MSCPComplianceService.evaluate(
            rows: [],
            baselines: [makeBaseline(stig)]
        )
        let r = try! XCTUnwrap(results.first)
        XCTAssertNil(r.compliancePct,
                     "No rows for baseline → compliancePct nil → ReportEngine must keep proxy")
    }

    func testEmptyRowsNoDataCountIsZeroTotalIsZero() {
        let results = MSCPComplianceService.evaluate(
            rows: [],
            baselines: [makeBaseline(stig)]
        )
        let r = try! XCTUnwrap(results.first)
        XCTAssertEqual(r.noDataCount, 0)
        XCTAssertEqual(r.totalDevices, 0)
    }

    // MARK: Empty baselines list → empty results

    func testEmptyBaselinesReturnsEmptyResults() {
        let results = MSCPComplianceService.evaluate(rows: makeRows(), baselines: [])
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: Legacy shape (computer_id instead of device)

    func testLegacyComputerIdShapeIsJoined() {
        let rows: [EAResultRow] = [
            .init(computerId: "cid-100", eaName: stig, value: 0),
            .init(computerId: "cid-101", eaName: stig, value: 15),
        ]
        let results = MSCPComplianceService.evaluate(rows: rows, baselines: [makeBaseline(stig)])
        let r = try! XCTUnwrap(results.first)
        XCTAssertEqual(r.totalDevices, 2)
        XCTAssertEqual(r.noDataCount, 0)
        // Pass = 1, Med-Low = 1
        let byLabel = Dictionary(uniqueKeysWithValues: r.bands.map { ($0.label, $0.count) })
        XCTAssertEqual(byLabel["Pass"], 1)
        XCTAssertEqual(byLabel["Med-Low"], 1)
    }

    // MARK: Case-insensitive EA name match

    func testEANameMatchIsCaseInsensitive() {
        let mixedCaseName = stig.lowercased()
        let rows: [EAResultRow] = [
            .init(device: "mac-x", eaName: mixedCaseName, value: 0),
        ]
        let results = MSCPComplianceService.evaluate(rows: rows, baselines: [makeBaseline(stig)])
        let r = try! XCTUnwrap(results.first)
        let byLabel = Dictionary(uniqueKeysWithValues: r.bands.map { ($0.label, $0.count) })
        XCTAssertEqual(byLabel["Pass"], 1,
                       "EA name match must be case-insensitive")
    }

    // MARK: Unparseable value treated as No Data

    func testUnparseableValueTreatedAsNoData() {
        let rows: [EAResultRow] = [
            EAResultRow(
                computerId: nil, computerName: nil, serial: nil, eaId: nil,
                eaName: stig, device: "mac-bad",
                value: AnyCodable("not-a-number")
            ),
            .init(device: "mac-ok", eaName: stig, value: 0),
        ]
        let results = MSCPComplianceService.evaluate(rows: rows, baselines: [makeBaseline(stig)])
        let r = try! XCTUnwrap(results.first)
        XCTAssertEqual(r.noDataCount, 1, "Unparseable value should be No Data")
        XCTAssertEqual(r.devicesWithData, 1)
    }

    // MARK: resolvedBaselines backward compat

    func testResolvedBaselinesFromLegacyFailuresCountColumn() {
        let config = ComplianceConfig(
            enabled: true,
            failuresCountColumn: nist,
            failuresListColumn: nil,
            baselineLabel: "NIST Audit",
            framework: nil,
            baselines: nil
        )
        let resolved = config.resolvedBaselines
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].failuresCountColumn, nist)
        XCTAssertEqual(resolved[0].name, "NIST Audit")
    }

    func testResolvedBaselinesExplicitListTakesPrecedence() {
        let explicit = [ComplianceBaselineConfig(name: "STIG", failuresCountColumn: stig, ruleCount: nil)]
        let config = ComplianceConfig(
            enabled: true,
            failuresCountColumn: nist,
            failuresListColumn: nil,
            baselineLabel: "Old label",
            framework: nil,
            baselines: explicit
        )
        let resolved = config.resolvedBaselines
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].name, "STIG")
        XCTAssertEqual(resolved[0].failuresCountColumn, stig)
    }

    func testResolvedBaselinesEmptyWhenNeitherConfigured() {
        let config = ComplianceConfig(
            enabled: nil,
            failuresCountColumn: nil,
            failuresListColumn: nil,
            baselineLabel: nil,
            framework: nil,
            baselines: nil
        )
        XCTAssertTrue(config.resolvedBaselines.isEmpty)
    }

    // MARK: Config JSON decoding (verifies CodingKeys snake_case)

    /// Verifies that `baselines` decodes through the real JSON decoder with
    /// snake_case keys (`failures_count_column`, `rule_count`). If the CodingKeys
    /// are wrong the list silently decodes to nil and the feature no-ops at runtime.
    func testBaselinesDecodesFromJSON() throws {
        let json = """
        {
          "compliance": {
            "enabled": true,
            "baselines": [
              {
                "name": "NIST 800-53r5",
                "failures_count_column": "Compliance - Failed mSCP Results Count - NIST 800-53r5 Audit",
                "rule_count": 315
              },
              {
                "name": "DISA STIG",
                "failures_count_column": "Compliance - Failed mSCP Results Count - DISA STIG"
              }
            ]
          }
        }
        """
        let config = try JSONDecoder().decode(ReportConfig.self, from: Data(json.utf8))
        let baselines = try XCTUnwrap(config.compliance?.baselines,
                                      "baselines must decode; CodingKeys or JSON may be wrong")
        XCTAssertEqual(baselines.count, 2)
        XCTAssertEqual(baselines[0].name, "NIST 800-53r5")
        XCTAssertEqual(baselines[0].failuresCountColumn,
                       "Compliance - Failed mSCP Results Count - NIST 800-53r5 Audit")
        XCTAssertEqual(baselines[0].ruleCount, 315)
        XCTAssertEqual(baselines[1].name, "DISA STIG")
        XCTAssertNil(baselines[1].ruleCount, "rule_count must be nil when absent")
    }

    /// Verifies that a legacy config (failures_count_column only, no baselines)
    /// decodes without error and resolvedBaselines synthesizes one entry.
    func testLegacyConfigDecodesAndResolves() throws {
        let json = """
        {
          "compliance": {
            "enabled": true,
            "baseline_label": "mSCP Baseline",
            "failures_count_column": "Compliance - Failed mSCP Results Count - NIST 800-53r5"
          }
        }
        """
        let config = try JSONDecoder().decode(ReportConfig.self, from: Data(json.utf8))
        let resolved = try XCTUnwrap(config.compliance?.resolvedBaselines)
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].name, "mSCP Baseline")
        XCTAssertEqual(resolved[0].failuresCountColumn,
                       "Compliance - Failed mSCP Results Count - NIST 800-53r5")
    }

    // MARK: - Improvement 2: column-mismatch is detectable from BaselineResult

    /// When `failures_count_column` doesn't match any EA row — the prod symptom
    /// of an all-No-Data donut — `devicesWithData` must be 0 and
    /// `failuresCountColumn` must surface the configured column name so the UI
    /// can show a diagnostic caption.
    func testDevicesWithDataIsZeroWhenColumnNameDoesNotMatch() {
        let configuredColumn = "Compliance Failures Count NIST"  // intentional typo vs actual EA name
        let actualEAName     = "Compliance - Failed mSCP Results Count - NIST 800-53r5"

        let rows = [
            EAResultRow(device: "mac-001", eaName: actualEAName, value: 0),
            EAResultRow(device: "mac-002", eaName: actualEAName, value: 5),
            EAResultRow(device: "mac-003", eaName: actualEAName, value: 20),
        ]

        let baseline = ComplianceBaselineConfig(
            name: "NIST", failuresCountColumn: configuredColumn, ruleCount: nil)
        let results = MSCPComplianceService.evaluate(rows: rows, baselines: [baseline])
        let result = results.first!

        XCTAssertEqual(result.devicesWithData, 0,
            "A column name that matches no EA row must produce devicesWithData == 0")
        XCTAssertEqual(result.totalDevices, 3,
            "totalDevices must reflect the full universe even when the column doesn't match")
        XCTAssertEqual(result.failuresCountColumn, configuredColumn,
            "failuresCountColumn must surface the configured column name for diagnostic UI")
        XCTAssertNil(result.compliancePct,
            "compliancePct must be nil when devicesWithData == 0")
    }

    /// Baseline result with correct column shows non-zero devicesWithData —
    /// regression guard to confirm the diagnostic path is narrow.
    func testDevicesWithDataIsNonZeroWhenColumnNameMatches() {
        let col = "Compliance - Failed mSCP Results Count - NIST 800-53r5"
        let rows = [
            EAResultRow(device: "mac-001", eaName: col, value: 0),
            EAResultRow(device: "mac-002", eaName: col, value: 5),
        ]
        let baseline = ComplianceBaselineConfig(name: "NIST", failuresCountColumn: col, ruleCount: nil)
        let results = MSCPComplianceService.evaluate(rows: rows, baselines: [baseline])
        let result = results.first!

        XCTAssertEqual(result.devicesWithData, 2)
        XCTAssertNotNil(result.compliancePct)
    }

    // MARK: - Task 1: rule-count validity bound

    /// A count above the baseline's rule count is a garbage EA value → No Data,
    /// never High.
    func testCountAboveRuleCountBecomesNoData() {
        let rows: [EAResultRow] = [
            .init(device: "mac-garbage", eaName: stig, value: 9999),  // > ruleCount
            .init(device: "mac-ok", eaName: stig, value: 0),
        ]
        let baseline = ComplianceBaselineConfig(
            name: "STIG", failuresCountColumn: stig, ruleCount: 280)
        let results = MSCPComplianceService.evaluate(rows: rows, baselines: [baseline])
        let r = try! XCTUnwrap(results.first)

        let byLabel = Dictionary(uniqueKeysWithValues: r.bands.map { ($0.label, $0.count) })
        XCTAssertEqual(byLabel["No Data"], 1, "count > ruleCount must be No Data")
        // bands includes zero-count entries, so High is present with count 0.
        XCTAssertEqual(byLabel["High"], 0, "the garbage device must NOT band High")
        XCTAssertEqual(r.devicesWithData, 1, "only mac-ok has a valid count")
    }

    /// A count equal to the rule count is still valid (boundary is inclusive).
    func testCountEqualToRuleCountIsValid() {
        let rows: [EAResultRow] = [.init(device: "mac-edge", eaName: stig, value: 280)]
        let baseline = ComplianceBaselineConfig(
            name: "STIG", failuresCountColumn: stig, ruleCount: 280)
        let results = MSCPComplianceService.evaluate(rows: rows, baselines: [baseline])
        let r = try! XCTUnwrap(results.first)
        XCTAssertEqual(r.devicesWithData, 1, "count == ruleCount is in-bounds")
    }

    /// With no ruleCount configured, the bound is off — a huge count still bands
    /// High (pins today's unbounded default behavior).
    func testNilRuleCountLeavesHugeCountBandedHigh() {
        let rows: [EAResultRow] = [.init(device: "mac-huge", eaName: stig, value: 9999)]
        let baseline = ComplianceBaselineConfig(
            name: "STIG", failuresCountColumn: stig, ruleCount: nil)
        let results = MSCPComplianceService.evaluate(rows: rows, baselines: [baseline])
        let r = try! XCTUnwrap(results.first)
        let byLabel = Dictionary(uniqueKeysWithValues: r.bands.map { ($0.label, $0.count) })
        XCTAssertEqual(byLabel["High"], 1, "no ruleCount → no bound → still High")
        XCTAssertEqual(r.devicesWithData, 1)
    }

    // MARK: - Task 2: count-vs-list cross-check

    private func crossCheckBaseline() -> ComplianceBaselineConfig {
        ComplianceBaselineConfig(
            name: "STIG", failuresCountColumn: stig,
            failuresListColumn: stigList, ruleCount: 280)
    }

    func testCrossCheckAgreement() {
        let rows: [EAResultRow] = [
            .init(device: "mac-001", eaName: stig, value: 2),
            .init(device: "mac-001", eaName: stigList, stringValue: "os_ssh_disable|os_filevault_enable"),
        ]
        let results = MSCPComplianceService.crossCheck(rows: rows, baselines: [crossCheckBaseline()])
        let r = try! XCTUnwrap(results.first)
        XCTAssertEqual(r.baselineName, "STIG")
        XCTAssertEqual(r.devicesCompared, 1)
        XCTAssertEqual(r.disagreements, 0)
        XCTAssertEqual(r.disagreementRate, 0.0)
    }

    func testCrossCheckDisagreement() {
        let rows: [EAResultRow] = [
            .init(device: "mac-001", eaName: stig, value: 12),
            .init(device: "mac-001", eaName: stigList, stringValue: "a|b|c"),  // 3 entries != 12
        ]
        let results = MSCPComplianceService.crossCheck(rows: rows, baselines: [crossCheckBaseline()])
        let r = try! XCTUnwrap(results.first)
        XCTAssertEqual(r.devicesCompared, 1)
        XCTAssertEqual(r.disagreements, 1)
        XCTAssertEqual(r.disagreementRate, 1.0)
    }

    func testCrossCheckBlankListCellAgreesWithCountZero() {
        let rows: [EAResultRow] = [
            .init(device: "mac-001", eaName: stig, value: 0),
            .init(device: "mac-001", eaName: stigList, stringValue: "   "),  // blank → 0 entries
        ]
        let results = MSCPComplianceService.crossCheck(rows: rows, baselines: [crossCheckBaseline()])
        let r = try! XCTUnwrap(results.first)
        XCTAssertEqual(r.devicesCompared, 1)
        XCTAssertEqual(r.disagreements, 0, "blank list (0 entries) agrees with count 0")
    }

    func testCrossCheckDeviceMissingOneSideIsSkipped() {
        let rows: [EAResultRow] = [
            // mac-001 has both → compared
            .init(device: "mac-001", eaName: stig, value: 1),
            .init(device: "mac-001", eaName: stigList, stringValue: "os_ssh_disable"),
            // mac-002 has only a count → skipped
            .init(device: "mac-002", eaName: stig, value: 4),
            // mac-003 has only a list → skipped
            .init(device: "mac-003", eaName: stigList, stringValue: "a|b"),
        ]
        let results = MSCPComplianceService.crossCheck(rows: rows, baselines: [crossCheckBaseline()])
        let r = try! XCTUnwrap(results.first)
        XCTAssertEqual(r.devicesCompared, 1, "only mac-001 has both sides")
        XCTAssertEqual(r.disagreements, 0)
    }

    func testCrossCheckOmitsBaselineWithoutListColumn() {
        let withList = crossCheckBaseline()
        let withoutList = ComplianceBaselineConfig(
            name: "NIST", failuresCountColumn: nist, ruleCount: nil)  // no list column
        let rows: [EAResultRow] = [
            .init(device: "mac-001", eaName: stig, value: 1),
            .init(device: "mac-001", eaName: stigList, stringValue: "x"),
            .init(device: "mac-001", eaName: nist, value: 0),
        ]
        let results = MSCPComplianceService.crossCheck(
            rows: rows, baselines: [withList, withoutList])
        XCTAssertEqual(results.count, 1, "only the list-configured baseline is returned")
        XCTAssertEqual(results[0].baselineName, "STIG")
    }

    func testCrossCheckGarbageCountExcludedFromComparison() {
        let rows: [EAResultRow] = [
            .init(device: "mac-001", eaName: stig, value: 9999),  // > ruleCount → invalid count
            .init(device: "mac-001", eaName: stigList, stringValue: "a|b"),
        ]
        let results = MSCPComplianceService.crossCheck(rows: rows, baselines: [crossCheckBaseline()])
        let r = try! XCTUnwrap(results.first)
        XCTAssertEqual(r.devicesCompared, 0,
                       "an out-of-bounds count has no valid count side → device skipped")
        XCTAssertNil(r.disagreementRate)
    }

    // MARK: - Task 2: resolvedBaselines carries failures_list_column

    func testResolvedBaselinesCarriesLegacyFailuresListColumn() {
        let config = ComplianceConfig(
            enabled: true,
            failuresCountColumn: stig,
            failuresListColumn: stigList,
            baselineLabel: "STIG",
            framework: nil,
            baselines: nil
        )
        let resolved = config.resolvedBaselines
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].failuresListColumn, stigList,
                       "legacy synthesis must carry failures_list_column")
    }

    /// The new per-baseline `failures_list_column` key decodes through JSON.
    func testBaselineFailuresListColumnDecodesFromJSON() throws {
        let json = """
        {
          "compliance": {
            "enabled": true,
            "baselines": [
              {
                "name": "DISA STIG",
                "failures_count_column": "Compliance - Failed mSCP Results Count - DISA STIG",
                "failures_list_column": "Compliance - Failed mSCP Result List - DISA STIG",
                "rule_count": 280
              }
            ]
          }
        }
        """
        let config = try JSONDecoder().decode(ReportConfig.self, from: Data(json.utf8))
        let baselines = try XCTUnwrap(config.compliance?.baselines)
        XCTAssertEqual(baselines.count, 1)
        XCTAssertEqual(baselines[0].failuresListColumn,
                       "Compliance - Failed mSCP Result List - DISA STIG")
        XCTAssertEqual(baselines[0].ruleCount, 280)
    }
}
