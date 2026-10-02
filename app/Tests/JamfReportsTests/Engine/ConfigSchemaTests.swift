import Foundation
import XCTest
@testable import JamfReports

final class ConfigSchemaTests: XCTestCase {

    private func unknownKeys(_ yaml: String) throws -> [UnknownKey] {
        ConfigSchema.unknownKeys(in: try ConfigLoader.rawMapping(fromYAML: yaml))
    }

    // MARK: - The walk

    func testMisspelledKeysAreReportedWithTheirPathAndNearestKey() throws {
        let keys = try unknownKeys("""
        thresholdz:
          stale_device_days: 30
          not_a_setting: 1
        output:
          output_dir: "Reports"
          keep_lastest_runs: 5
        custom_eas:
          - name: "Disk Use"
            column: "Boot Drive Percentage Full"
            type: percentage
            warning_threshold: 80
          - name: "Battery Cycles"
            column: "Battery Cycle Count"
            type: percentage
            warning_treshold: 80
        """)
        XCTAssertEqual(keys, [
            UnknownKey(keyPath: "custom_eas[1].warning_treshold", suggestion: "warning_threshold"),
            UnknownKey(keyPath: "output.keep_lastest_runs", suggestion: "keep_latest_runs"),
            UnknownKey(keyPath: "thresholdz", suggestion: "thresholds"),
        ], "an unknown top-level key is reported once, not once per key under it")
    }

    func testACorrectFileHasNoUnknownKeys() throws {
        let keys = try unknownKeys("""
        columns:
          computer_name: "Computer Name"
          purchase_date: "Purchase Date"
        output:
          output_dir: "Reports"
          allow_absolute_paths: false
        html:
          track_history: true
          history_file: "history.json"
          section_limits:
            protect_alerts: 25
        security_policy:
          controls:
            filevault: warning
          filevault_off_hardware_encrypted: ignore
          score_weights:
            filevault: 15
            sip: 15
            firewall: 15
            edr_agent: 10
            mscp: 20
            xprotect: 5
            cve: 15
            secure_boot: 5
        ai:
          external:
            provider: ""
        """)
        XCTAssertEqual(keys, [])
    }

    func testEveryListOfMappingsIsWalked() throws {
        let keys = try unknownKeys("""
        security_agents:
          - name: "Agent"
            column: "Agent Status"
            conected_value: "Running"
        alerts:
          rules:
            - metric: "filevault_pct"
              when: "below"
              treshold: 90
        exceptions:
          - id: "EX-1"
            description: "Lab Macs"
            signed_off_by: "Example Approver"
            signed_off_date: "2026-01-01"
            expires: "2027-01-01"
        compliance:
          baselines:
            - name: "Example Baseline"
              failures_count_column: "Example Failures"
              rule_cuont: 120
        charts:
          compliance_trend:
            bands:
              - {label: "Pass", min_failures: 0, max_failures: 0, colour: "#4472C4"}
        """)
        XCTAssertEqual(keys, [
            UnknownKey(keyPath: "alerts.rules[0].treshold", suggestion: "threshold"),
            UnknownKey(keyPath: "charts.compliance_trend.bands[0].colour", suggestion: "color"),
            UnknownKey(keyPath: "compliance.baselines[0].rule_cuont", suggestion: "rule_count"),
            UnknownKey(keyPath: "exceptions[0].expires", suggestion: nil),
            UnknownKey(keyPath: "security_agents[0].conected_value",
                       suggestion: "connected_value"),
        ])
    }

    func testUnknownKeysInsideSecurityPolicyAreReported() throws {
        let keys = try unknownKeys("""
        security_policy:
          controls:
            sip: fail
            antivirus: warning
          mode: strict
          score_weights:
            filevualt: 10
        """)
        XCTAssertEqual(keys.map(\.keyPath), [
            "security_policy.controls.antivirus",
            "security_policy.mode",
            "security_policy.score_weights.filevualt",
        ])
        XCTAssertEqual(keys.last?.suggestion, "filevault")
    }

    func testABlockOfTheWrongShapeIsLeftToTheDecoderError() throws {
        let keys = try unknownKeys("""
        custom_eas:
          name: "Disk Use"
        charts:
          - enabled: true
        """)
        XCTAssertEqual(keys, [], "the decoder already rejects these and names the key path")
    }

    // MARK: - Suggestions

    func testASuggestionIsTheOnlyKnownKeyWithinTwoEdits() throws {
        let keys = try unknownKeys("""
        jamf-cli:
          profile: "example"
        Columns:
          email: "Email"
        columns:
          fierwall: "Firewall"
          asset_number: "Asset"
        """)
        XCTAssertEqual(keys, [
            UnknownKey(keyPath: "Columns", suggestion: "columns"),
            UnknownKey(keyPath: "columns.asset_number", suggestion: nil),
            UnknownKey(keyPath: "columns.fierwall", suggestion: "firewall"),
            UnknownKey(keyPath: "jamf-cli", suggestion: "jamf_cli"),
        ], "keys are compared as written; a dash for an underscore is one edit")
    }

    func testTwoEquallyNearKnownKeysGiveNoSuggestion() throws {
        // `skly` is two edits from both `skip` and `only`.
        let keys = try unknownKeys("""
        sheets:
          skly: []
          ordr: []
        """)
        XCTAssertEqual(keys, [
            UnknownKey(keyPath: "sheets.ordr", suggestion: "order"),
            UnknownKey(keyPath: "sheets.skly", suggestion: nil),
        ])
    }

    // MARK: - Known misnames

    /// The wrong names CLAUDE.md's "Actual key names" table lists, each with its right key.
    func testEachKnownMisnameSuggestsTheKeyItMeans() throws {
        let keys = try unknownKeys("""
        columns:
          os_version: "OS"
          last_contact: "Last Contact"
          assigned_user_email: "Email"
        jamf_cli:
          jamf_profile: "example"
          live_overview: true
        security_agents:
          - name: "Agent"
            column: "Agent Status"
            installed_value: "Installed"
        compliance:
          failed_count_column: "Failures"
          failed_list_column: "Failure List"
        custom_eas:
          - name: "Disk Use"
            column: "Boot Drive Percentage Full"
            type: percentage
          - name: "Status"
            column: "Agent Status"
            type: text
          - name: "Mixed"
            column: "Mixed Column"
            type: boolean
            compliant_value: "Yes"
            high_threshold: 90
            min_version: "15.0"
            warn_within_days: 30
        thresholds:
          inactive_device_days: 60
        output:
          directory: "Reports"
          max_runs: 5
        charts:
          snapshot_dir: "snapshots"
          auto_archive: true
        """)
        let suggested = Dictionary(uniqueKeysWithValues: keys.map { ($0.keyPath, $0.suggestion) })
        XCTAssertEqual(keys.count, 17)
        XCTAssertEqual(suggested["columns.os_version"], "operating_system")
        XCTAssertEqual(suggested["columns.last_contact"], "last_checkin")
        XCTAssertEqual(suggested["columns.assigned_user_email"], "email")
        XCTAssertEqual(suggested["jamf_cli.jamf_profile"], "profile")
        XCTAssertEqual(suggested["jamf_cli.live_overview"], "allow_live_overview")
        XCTAssertEqual(suggested["security_agents[0].installed_value"], "connected_value")
        XCTAssertEqual(suggested["compliance.failed_count_column"], "failures_count_column")
        XCTAssertEqual(suggested["compliance.failed_list_column"], "failures_list_column")
        XCTAssertEqual(suggested["custom_eas[2].compliant_value"], "true_value")
        XCTAssertEqual(suggested["custom_eas[2].high_threshold"], "critical_threshold")
        XCTAssertEqual(suggested["custom_eas[2].min_version"], "current_versions")
        XCTAssertEqual(suggested["custom_eas[2].warn_within_days"], "warning_days")
        XCTAssertEqual(suggested["thresholds.inactive_device_days"], "stale_device_days")
        XCTAssertEqual(suggested["output.directory"], "output_dir")
        XCTAssertEqual(suggested["output.max_runs"], "keep_latest_runs")
        XCTAssertEqual(suggested["charts.snapshot_dir"], "historical_csv_dir")
        XCTAssertEqual(suggested["charts.auto_archive"], "archive_current_csv")
    }

    /// A misname must point at a key the schema knows there, and must not itself be known.
    func testEveryMisnameNamesAKeyTheSchemaKnowsAtItsPath() {
        XCTAssertFalse(ConfigSchema.misnames.isEmpty)
        for (path, pairs) in ConfigSchema.misnames {
            let known = ConfigSchema.knownKeys(at: path) ?? []
            let label = path.joined(separator: ".")
            for (wrong, right) in pairs {
                XCTAssertTrue(known.contains(right), "\(label): \(right) is not a known key")
                XCTAssertFalse(known.contains(wrong), "\(label): \(wrong) is a known key")
            }
        }
    }

    // MARK: - Display

    func testAnUnknownKeyIsShownWithoutControlCharactersAndCapped() throws {
        let long = String(repeating: "k", count: 70)
        let keys = try unknownKeys(
            "columns:\n  bad\u{1B}[31m\u{202E}key: \"x\"\n  \(long): \"y\"\n")
        XCTAssertEqual(keys.map(\.keyPath), [
            "columns.bad[31mkey",
            "columns." + String(repeating: "k", count: 59) + "…",
        ])
    }

    func testDisplayTextStripsControlCharactersAndCapsAtSixtyCharacters() {
        XCTAssertEqual(ConfigSchema.displayText("a\u{7}b\nc\t\u{202E}d\u{2028}e"), "abcde")
        let sixty = String(repeating: "x", count: 60)
        XCTAssertEqual(ConfigSchema.displayText(sixty), sixty)
        XCTAssertEqual(ConfigSchema.displayText(sixty + "y"),
                       String(repeating: "x", count: 59) + "…")
        XCTAssertEqual(ConfigSchema.displayText(""), "")
    }

    /// One character can carry thousands of combining marks; the scalar cap bounds it.
    func testDisplayTextBoundsUnicodeScalarsAtFourTimesTheCharacterCap() {
        let heavy = "e" + String(repeating: "\u{301}", count: 5_000)
        let shown = ConfigSchema.displayText(heavy)
        XCTAssertTrue(shown.hasSuffix("…"))
        XCTAssertLessThanOrEqual(shown.unicodeScalars.count, 241)

        let fourScalarsEach = String(repeating: "e\u{301}\u{302}\u{303}", count: 60)
        XCTAssertEqual(ConfigSchema.displayText(fourScalarsEach), fourScalarsEach,
                       "240 scalars is within the cap")
        let fiveScalarsEach = String(repeating: "e\u{301}\u{302}\u{303}\u{304}", count: 60)
        let cut = ConfigSchema.displayText(fiveScalarsEach)
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertLessThanOrEqual(cut.unicodeScalars.count, 241)
    }

    // MARK: - Known keys

    func testKnownKeysAtTheRootAreTheTopLevelBlocks() {
        let top = ConfigSchema.knownKeys(at: [])
        XCTAssertEqual(top?.contains("columns"), true)
        XCTAssertEqual(top?.contains("security_policy"), true)
        XCTAssertEqual(ConfigSchema.knownKeys(at: ["custom_eas"])?.contains("true_value"), true,
                       "a list of mappings is addressed by its key")
    }

    func testKnownKeysIsNilWhereNoMappingIsRead() {
        XCTAssertNil(ConfigSchema.knownKeys(at: ["columns", "computer_name"]), "a scalar")
        XCTAssertNil(ConfigSchema.knownKeys(at: ["sheets", "only"]), "a list of names")
        XCTAssertNil(ConfigSchema.knownKeys(at: ["not_a_block"]), "an unknown key")
    }

    func testKeysReadOutsideTheDecoderAreKnown() {
        XCTAssertEqual(ConfigSchema.knownKeys(at: ["output"])?.contains("allow_absolute_paths"),
                       true)
        let html = ConfigSchema.knownKeys(at: ["html"]) ?? []
        XCTAssertTrue(html.isSuperset(of: ["track_history", "history_file", "section_limits"]))
        XCTAssertEqual(ConfigSchema.knownKeys(at: ["security_policy", "score_weights"]), [
            "filevault", "sip", "firewall", "edr_agent", "mscp", "xprotect", "cve",
            "secure_boot",
        ])
    }

    func testEveryKeyTheDecoderReadsIsKnown() {
        func keys<Key: CodingKey & CaseIterable>(_ type: Key.Type) -> Set<String> {
            Set(type.allCases.map(\.stringValue))
        }
        let decoded: [([String], Set<String>)] = [
            ([], keys(ReportConfig.CodingKeys.self)),
            (["columns"], keys(ColumnConfig.CodingKeys.self)),
            (["mobile_columns"], keys(MobileColumnConfig.CodingKeys.self)),
            (["security_agents"], keys(SecurityAgentConfig.CodingKeys.self)),
            (["jamf_cli"], keys(JamfCLIConfig.CodingKeys.self)),
            (["compliance"], keys(ComplianceConfig.CodingKeys.self)),
            (["compliance", "baselines"], keys(ComplianceBaselineConfig.CodingKeys.self)),
            (["custom_eas"], keys(CustomEAConfig.CodingKeys.self)),
            (["exceptions"], keys(ConfigException.CodingKeys.self)),
            (["sheets"], keys(SheetsConfig.CodingKeys.self)),
            (["thresholds"], keys(ThresholdsConfig.CodingKeys.self)),
            (["output"], keys(OutputConfig.CodingKeys.self)),
            (["charts"], keys(ChartsConfig.CodingKeys.self)),
            (["charts", "os_adoption"], keys(OSAdoptionConfig.CodingKeys.self)),
            (["charts", "compliance_trend"], keys(ComplianceTrendConfig.CodingKeys.self)),
            (["charts", "compliance_trend", "bands"], keys(ComplianceBandConfig.CodingKeys.self)),
            (["charts", "device_state_trend"], keys(DeviceStateTrendConfig.CodingKeys.self)),
            (["branding"], keys(BrandingConfig.CodingKeys.self)),
            (["platform"], keys(PlatformConfig.CodingKeys.self)),
            (["protect"], keys(ProtectConfig.CodingKeys.self)),
            (["school_cli"], keys(SchoolCLIConfig.CodingKeys.self)),
            (["notify"], keys(NotifyConfig.CodingKeys.self)),
            (["alerts"], keys(AlertsConfig.CodingKeys.self)),
            (["alerts", "rules"], keys(AlertRule.CodingKeys.self)),
            (["retention"], keys(RetentionConfig.CodingKeys.self)),
            (["shared_workspace"], keys(SharedWorkspaceConfig.CodingKeys.self)),
            (["ai"], keys(AIConfig.CodingKeys.self)),
            (["ai", "external"], keys(AIExternalConfig.CodingKeys.self)),
            (["html"], keys(HTMLReportConfig.CodingKeys.self)),
            (["html", "section_limits"], keys(HTMLSectionLimits.CodingKeys.self)),
            (["security_policy"], keys(SecurityControlPolicy.CodingKeys.self)),
            (["security_policy", "controls"], keys(SecurityControlPolicy.ControlKeys.self)),
        ]
        for (path, expected) in decoded {
            let label = path.isEmpty ? "<root>" : path.joined(separator: ".")
            guard let known = ConfigSchema.knownKeys(at: path) else {
                XCTFail("\(label): the schema has no mapping here")
                continue
            }
            XCTAssertTrue(expected.isSubset(of: known),
                          "\(label): missing \(expected.subtracting(known).sorted())")
        }
    }

    // MARK: - The shipped example

    /// The example documents only keys the app reads, so it must report none.
    func testTheShippedExampleConfigHasNoUnknownKeys() throws {
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
        let keys = try unknownKeys(String(contentsOf: example, encoding: .utf8))
        XCTAssertEqual(keys, [])
        XCTAssertEqual(ConfigDoctorService.unknownKeyRows(keys), [])
    }
}
