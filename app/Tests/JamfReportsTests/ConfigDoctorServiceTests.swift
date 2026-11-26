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

    /// One collected ea-results row per value of `column`.
    private func eaValues(_ column: String, _ values: [String]) -> [EAResultRow] {
        values.enumerated().map {
            EAResultRow(device: "d\($0.offset)", eaName: column, stringValue: $0.element)
        }
    }

    /// A clean config: nothing to flag.
    private let cleanYAML = """
    compliance:
      enabled: false
    """

    // MARK: - Parse

    func testParseErrorEmitsSingleFailRow() {
        let rows = ConfigDoctorService.evaluate(
            config: nil,
            parseError: "compliance.bands[0]: missing 'label'",
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
            parseError: nil, eaCoverageNames: []
        )
        XCTAssertFalse(rows.contains { $0.severity == .fail }, "clean config must not fail")
        XCTAssertFalse(rows.contains { $0.severity == .warn }, "clean config must not warn")
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
            parseError: nil, eaCoverageNames: []
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
            parseError: nil, eaCoverageNames: ["Some Other EA"]
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
            parseError: nil, eaCoverageNames: []
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
            parseError: nil, eaCoverageNames: ["failed mscp count"]  // case-insensitive match
        )
        let baseline = rows.first { $0.id.hasPrefix("compliance.baseline.") }
        XCTAssertEqual(baseline?.severity, .pass)
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
            config: config, parseError: nil, eaCoverageNames: []
        )
        XCTAssertEqual(row(rows, id: "custom_ea.FileVault.true_value")?.severity, .warn)
    }

    // MARK: - custom_eas against the collected results

    /// One EA whose column is a collected EA name, one whose column is not.
    private let collectedEAYAML = """
    custom_eas:
      - name: "FileVault"
        column: "FileVault 2 Status"
        type: text
      - name: "Battery"
        column: "Battery Health"
        type: text
    """

    /// A column that names a collected extension attribute gets its sheet from the results,
    /// matched case-insensitively.
    func testCustomEAWithCollectedValuesPasses() throws {
        let rows = ConfigDoctorService.evaluate(
            config: try makeConfig(collectedEAYAML), parseError: nil,
            eaCoverageNames: ["filevault 2 status"],
            eaDefinitionNames: ["FileVault 2 Status", "Battery Health"]
        )
        XCTAssertEqual(row(rows, id: "custom_ea.FileVault.ea_results")?.severity, .pass)
        let battery = try XCTUnwrap(row(rows, id: "custom_ea.Battery.ea_results"))
        XCTAssertEqual(battery.severity, .warn, "defined, but no Mac has a value")
        XCTAssertTrue(battery.detail.contains("No collected values"), "got: \(battery.detail)")
    }

    func testCustomEANotDefinedInJamfProWarnsAndSaysSo() throws {
        let rows = ConfigDoctorService.evaluate(
            config: try makeConfig(collectedEAYAML), parseError: nil,
            eaCoverageNames: ["FileVault 2 Status"],
            eaDefinitionNames: ["FileVault 2 Status", "Other"]
        )
        let battery = try XCTUnwrap(row(rows, id: "custom_ea.Battery.ea_results"))
        XCTAssertEqual(battery.severity, .warn)
        XCTAssertTrue(battery.detail.contains("not an extension attribute defined"),
                      "got: \(battery.detail)")
    }

    /// An EA with no column configured has nothing to look for.
    func testCustomEAWithEmptyColumnGetsNoResultsRow() throws {
        let yaml = """
        custom_eas:
          - name: "Unmapped"
            column: ""
            type: text
        """
        let rows = ConfigDoctorService.evaluate(
            config: try makeConfig(yaml), parseError: nil, eaCoverageNames: []
        )
        XCTAssertNil(row(rows, id: "custom_ea.Unmapped.ea_results"))
    }

    /// Only `.fail` rows reach a scheduled run's log. A jamf-cli-only workspace with
    /// EAs configured is valid, so these rows must never be able to turn a run red.
    func testCustomEAResultRowsNeverFail() throws {
        let coverages: [[String]] = [
            [], ["FileVault 2 Status"], ["FileVault 2 Status", "Battery Health"],
        ]
        for coverage in coverages {
            let rows = ConfigDoctorService.evaluate(
                config: try makeConfig(collectedEAYAML), parseError: nil, eaCoverageNames: coverage
            )
            let mine = rows.filter { $0.id.hasSuffix(".ea_results") }
            XCTAssertEqual(mine.count, 2, "one row per mapped EA; coverage: \(coverage)")
            XCTAssertFalse(mine.contains { $0.severity == .fail }, "coverage: \(coverage)")
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
            config: config, parseError: nil, eaCoverageNames: []
        )
        XCTAssertNil(row(rows, id: "platform.benchmarks"))
    }

    // MARK: - security_agents

    func testSecurityAgentEmptyColumnWarnsViaStructuralRows() throws {
        let yaml = """
        security_agents:
          - name: "CrowdStrike"
            column: ""
            connected_value: "Installed"
        """
        let config = try makeConfig(yaml)
        let rows = ConfigDoctorService.evaluate(
            config: config, parseError: nil, eaCoverageNames: []
        )
        XCTAssertEqual(
            row(rows, id: "security_agent.CrowdStrike.column.structural")?.severity, .warn
        )
    }

    // MARK: - Accuracy: cross-source reconciliation (check 1)

    /// `count` devices in ea-results, one row each.
    private func eaDevices(_ count: Int) -> [EAResultRow] {
        (1...count).map { EAResultRow(device: "d\($0)", eaName: "X", value: 1) }
    }

    func testReconciliationWithinToleranceEmitsOK() throws {
        let inputs = ConfigDoctorService.AccuracyInputs(
            computersCount: 105, eaRows: eaDevices(100), coverageDrift: nil
        )
        let rows = ConfigDoctorService.evaluateAccuracy(config: ReportConfig(), inputs: inputs)
        XCTAssertEqual(row(rows, id: "accuracy.reconciliation")?.severity, .pass)
    }

    func testReconciliationDivergenceWarnsNamingBothSources() throws {
        let inputs = ConfigDoctorService.AccuracyInputs(
            computersCount: 130, eaRows: eaDevices(100), coverageDrift: nil
        )
        let rows = ConfigDoctorService.evaluateAccuracy(config: ReportConfig(), inputs: inputs)
        let recon = row(rows, id: "accuracy.reconciliation")
        XCTAssertEqual(recon?.severity, .warn)
        XCTAssertTrue(recon?.detail.contains("100") ?? false)
        XCTAssertTrue(recon?.detail.contains("130") ?? false)
    }

    func testReconciliationSkippedWithFewerThanTwoSources() throws {
        let inputs = ConfigDoctorService.AccuracyInputs(
            computersCount: 100, eaRows: nil, coverageDrift: nil
        )
        let rows = ConfigDoctorService.evaluateAccuracy(config: ReportConfig(), inputs: inputs)
        XCTAssertNil(row(rows, id: "accuracy.reconciliation"),
                     "one source is not enough to reconcile")
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
        let eaRows = eaValues("Battery Health", good + bad)
        let inputs = ConfigDoctorService.AccuracyInputs(
            computersCount: nil, eaRows: eaRows, coverageDrift: nil
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
        let eaRows = eaValues("STIG Failures", good + counts)
        let inputs = ConfigDoctorService.AccuracyInputs(
            computersCount: nil, eaRows: eaRows, coverageDrift: nil
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
        let eaRows = eaValues("OS Version", good + bad)
        let inputs = ConfigDoctorService.AccuracyInputs(
            computersCount: nil, eaRows: eaRows, coverageDrift: nil
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
        let eaRows = eaValues("OS Version", ["15.4", "14.7.1"])
            + eaValues("State", ["Managed", "Managed"])
        let inputs = ConfigDoctorService.AccuracyInputs(
            computersCount: nil, eaRows: eaRows, coverageDrift: nil
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
            computersCount: nil, eaRows: eaRows, coverageDrift: nil
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
            computersCount: nil, eaRows: nil, coverageDrift: .computed(drops)
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
            computersCount: nil, eaRows: nil, coverageDrift: .computed(stable)
        )
        let rows = ConfigDoctorService.evaluateAccuracy(config: config, inputs: inputs)
        XCTAssertEqual(row(rows, id: "accuracy.coverage_drift.ok")?.severity, .pass)
    }

    func testCoverageDriftSkippedWhenNoDriftData() throws {
        let config = try makeConfig(cleanYAML)
        let inputs = ConfigDoctorService.AccuracyInputs(
            computersCount: nil, eaRows: nil, coverageDrift: nil
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
            computersCount: nil, eaRows: nil,
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
            computersCount: nil, eaRows: nil,
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
            computersCount: nil, eaRows: nil, coverageDrift: .computed([])
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
            computersCount: nil, eaRows: eaRows, coverageDrift: nil
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
            computersCount: nil, eaRows: eaRows, coverageDrift: nil
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
            computersCount: nil, eaRows: eaRows, coverageDrift: nil
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
            config: config, parseError: nil, eaCoverageNames: []
        )
        let rule = row(rows, id: "alerts.rule.0")
        XCTAssertEqual(rule?.severity, .fail)
        XCTAssertTrue(rule?.detail.contains("filevault_percent") ?? false)
        XCTAssertTrue(rule?.detail.contains("unknown metric") ?? false)
    }

    func testTheCredentialMetricAcceptsOnlyBelowAndDoctorSaysSo() throws {
        let yaml = """
        alerts:
          enabled: true
          rules:
            - metric: "server_credential_days_left"
              when: "above"
              threshold: 30
            - metric: "server_credential_days_left"
              when: "below"
              threshold: 30
        """
        let config = try makeConfig(yaml)
        let rows = ConfigDoctorService.evaluate(
            config: config, parseError: nil, eaCoverageNames: [])
        XCTAssertEqual(row(rows, id: "alerts.rule.0")?.severity, .fail)
        XCTAssertTrue(row(rows, id: "alerts.rule.0")?.detail.contains("only accepts 'below'") ?? false)
        XCTAssertNil(row(rows, id: "alerts.rule.1"))
        XCTAssertEqual(config.alerts?.resolvedRules.count, 1)
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
            config: config, parseError: nil, eaCoverageNames: []
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
            config: config, parseError: nil, eaCoverageNames: []
        )
        let armed = row(rows, id: "alerts.armed")
        XCTAssertEqual(armed?.severity, .pass)
        XCTAssertTrue(armed?.detail.contains("1 alert rule") ?? false)
        XCTAssertNil(row(rows, id: "alerts.notify_missing"))
    }

    func testNoAlertsBlockEmitsNoAlertsRows() throws {
        let config = try makeConfig(cleanYAML)
        let rows = ConfigDoctorService.evaluate(
            config: config, parseError: nil, eaCoverageNames: []
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

    /// `exceptions[].control_id` had no reader; 2.11 retired it, inside each list item.
    func testExceptionControlIDReadsAsRetiredInsideTheList() throws {
        let yaml = """
        exceptions:
          - id: "EXC-001"
            description: "Lab Macs"
            signed_off_by: "Security Officer"
            signed_off_date: "2026-01-15"
            control_id: "AC-2"
        """
        XCTAssertEqual(try makeConfig(yaml).exceptions?.first?.id, "EXC-001")
        try withWorkspace(yaml) { profile, _ in
            let rows = ConfigDoctorService.unknownKeyRows(profile: profile)
            XCTAssertEqual(rows.map(\.title), ["exceptions[0].control_id"])
            XCTAssertEqual(rows.map(\.detail), ["No longer read since 2.11."])
            XCTAssertEqual(rows.map(\.hint), ["Delete the line from config.yaml."])
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

    // MARK: csv-inbox

    func testACSVInboxWithFilesGetsOneSuggestionRowAndNothingStronger() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-inbox-\(UUID().uuidString)", isDirectory: true)
        let inbox = workspace.appendingPathComponent("csv-inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        XCTAssertEqual(ConfigDoctorService.csvInboxRows(workspace: workspace), [], "empty folder")
        try Data("a".utf8).write(to: inbox.appendingPathComponent("export.csv"))

        let rows = ConfigDoctorService.csvInboxRows(workspace: workspace)
        XCTAssertEqual(rows.map(\.severity), [.suggest])
        XCTAssertEqual(rows.first?.detail, "csv-inbox is no longer read since 2.11; you can delete it.")
        XCTAssertEqual(ConfigDoctorService.csvInboxRows(workspace: nil), [])
        XCTAssertEqual(ConfigDoctorService.csvInboxRows(
            workspace: workspace.appendingPathComponent("elsewhere")), [], "no csv-inbox")
    }

    func testALargeDataFolderWithRetentionOffSuggestsRetention() throws {
        let data = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-doctor-size-\(UUID().uuidString)", isDirectory: true)
        let kind = data.appendingPathComponent("computers", isDirectory: true)
        try FileManager.default.createDirectory(at: kind, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: data) }
        try Data(count: 200_000).write(to: kind.appendingPathComponent("computers_x.json"))

        XCTAssertEqual(
            ConfigDoctorService.dataFolderSizeRows(dataDir: data, retentionEnabled: false), [],
            "well under the limit")
        let rows = ConfigDoctorService.dataFolderSizeRows(
            dataDir: data, retentionEnabled: false, limit: 100_000)
        XCTAssertEqual(rows.map(\.id), ["retention.data_folder_size"])
        XCTAssertEqual(rows.map(\.severity), [.suggest])
        XCTAssertEqual(
            ConfigDoctorService.dataFolderSizeRows(
                dataDir: data, retentionEnabled: true, limit: 100_000), [],
            "retention already on")
        XCTAssertEqual(
            ConfigDoctorService.dataFolderSizeRows(dataDir: nil, retentionEnabled: false), [])
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
