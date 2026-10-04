import XCTest
@testable import JamfReports

/// The read-only "From config.yaml" tab: what the file holds that no Config-screen editor
/// shows, what the app does not read, and what the reader skipped.
final class ConfigFileSectionsTests: XCTestCase {

    private func build(_ yaml: String, edited: Set<[String]>? = nil) throws -> ConfigFileSections {
        if let edited {
            return try ConfigFileSections.build(fromYAML: yaml, edited: edited)
        }
        return try ConfigFileSections.build(fromYAML: yaml)
    }

    /// Each block as `name: keyPath=value, …`.
    private func summary(_ sections: ConfigFileSections) -> [String] {
        sections.fileOnly.map { block in
            block.name + ": "
                + block.settings.map { "\($0.keyPath)=\($0.value)" }.joined(separator: ", ")
        }
    }

    // MARK: - The three sections

    func testBuildsTheThreeSectionsFromAFile() throws {
        let yaml = """
        columns:
          computer_name: Name
          frobnicate: x
        jamf_cli:
          profile: demo
          data_dir: snapshots
          jamf_profile: other
        output:
          output_dir: Reports
          allow_absolute_paths: true
          just some words
        retention:
          enabled: true
          mode: archive
        compliance:
          enabled: true
          baselines:
            - name: Baseline One
              failures_count_column: Failures
              rule_count: 40
            - name: Baseline Two
              failures_count_column: Failures Two
        html:
          track_history: false
        """
        let sections = try build(yaml)

        XCTAssertEqual(summary(sections), [
            "jamf_cli: jamf_cli.profile=demo, jamf_cli.data_dir=snapshots",
            "output: output.allow_absolute_paths=true",
            "retention: retention.enabled=true, retention.mode=archive",
            "compliance: compliance.baselines[0].name=Baseline One, "
                + "compliance.baselines[0].failures_count_column=Failures, "
                + "compliance.baselines[0].rule_count=40, "
                + "compliance.baselines[1].name=Baseline Two, "
                + "compliance.baselines[1].failures_count_column=Failures Two",
            "html: html.track_history=false",
        ])
        XCTAssertEqual(
            sections.unknown.map(\.keyPath), ["columns.frobnicate", "jamf_cli.jamf_profile"])
        XCTAssertEqual(sections.unknown.map(\.suggestion), [nil, "profile"])
        let badLine = try XCTUnwrap(
            yaml.components(separatedBy: "\n").firstIndex { $0.contains("just some words") })
        XCTAssertEqual(sections.skipped, [
            "Line \(badLine + 1): no \"key: value\" on this line, so it was not read",
        ])
        XCTAssertFalse(sections.isEmpty)
    }

    func testAKeyAScreenEditsIsNotListed() throws {
        let yaml = """
        columns:
          computer_name: Name
          full_name: Full Name
        mobile_columns:
          model: Model
        security_agents:
          - name: Falcon
            column: Falcon Status
            connected_value: Installed
        custom_eas:
          - name: Disk
            column: Disk Used
            type: percentage
            warning_threshold: 70
            critical_threshold: 90
          - name: Agent
            column: Agent Version
            type: version
            current_versions:
              - "5.1"
          - name: Backup
            column: Backup OK
            type: boolean
            true_value: Yes
          - name: Cert
            column: Cert Expiry
            type: date
            warning_days: 30
        thresholds:
          stale_device_days: 45
          checkin_overdue_days: 5
        compliance:
          enabled: true
          baseline_label: Baseline
          failures_count_column: Failures
          failures_list_column: Failed Rules
        platform:
          enabled: true
          compliance_benchmarks:
            - Benchmark One
        output:
          output_dir: Reports
          archive_dir: Old
          timestamp_outputs: true
          archive_enabled: true
          keep_latest_runs: 5
        jamf_cli:
          use_cached_data: true
          require_manifest: false
        branding:
          org_name: Example Org
          logo_path: logo.png
          accent_color: "#112233"
          accent_dark: "#001122"
        charts:
          save_png: true
          os_adoption:
            per_major_charts: false
        notify:
          enabled: true
          provider: slack
          url: https://hooks.example.test/abc
          detail: minimal
        ai:
          enabled: true
          tier: on_device
          reasoning_level: deep
        """
        let sections = try build(yaml)
        XCTAssertEqual(summary(sections), [])
        XCTAssertEqual(sections.unknown, [])
        XCTAssertEqual(sections.skipped, [])
        XCTAssertTrue(sections.isEmpty)
    }

    /// The Scoring tab's cards write these; listing them as "not editable here" on the same
    /// screen would be wrong.
    func testTheSecurityPolicyKeysTheScoringTabEditsAreNotListed() throws {
        let yaml = """
        security_policy:
          controls:
            sip: warning
            firewall: ignore
          filevault_off_hardware_encrypted: warning
          score_weights:
            filevault: 20
            sip: 10
        """
        let sections = try build(yaml)
        XCTAssertEqual(summary(sections), [])
        XCTAssertEqual(sections.unknown, [])
    }

    func testAKeyNextToAnEditedOneIsStillListed() throws {
        let sections = try build(
            "charts:\n  save_png: true\n  historical_csv_dir: snaps\n"
                + "  os_adoption:\n    per_major_charts: true\n"
                + "  device_state_trend:\n    enabled: false\n")
        XCTAssertEqual(summary(sections), [
            "charts: charts.historical_csv_dir=snaps, charts.device_state_trend.enabled=false",
        ])
    }

    // MARK: - Values

    func testAValueUnderASecretLookingKeyIsNeverShown() throws {
        let url = "https://hooks.example.test/T000/B000/abcdef0123456789"
        let sections = try build(
            "notify:\n  url: \(url)\nprotect:\n  profile: p\n", edited: [])
        XCTAssertEqual(
            summary(sections), ["notify: notify.url=(set)", "protect: protect.profile=p"])
        XCTAssertFalse(String(describing: sections).contains("abcdef0123456789"))
        let empty = try build("notify:\n  url: \"\"\n", edited: [])
        XCTAssertEqual(summary(empty), ["notify: notify.url=(empty)"])
    }

    func testSecretLookingKeyNamesAreMatchedWhereverTheyAppearInThePath() {
        let value = YAMLCodec.YAMLValue.scalar(.string("x"))
        let paths = [
            "a.api_key", "a.Token", "a.client_secret", "a.passwordHint", "a.slack_webhook",
            "a.NOTIFY_URL",
        ]
        for path in paths {
            XCTAssertEqual(ConfigFileSections.displayValue(value, keyPath: path), "(set)", path)
        }
        XCTAssertEqual(ConfigFileSections.displayValue(value, keyPath: "a.mode"), "x")
    }

    func testAValueIsBoundedAndHasNoControlCharacters() throws {
        let long = "\u{1B}[31m" + String(repeating: "abcdefghij", count: 12)
        let sections = try build("retention:\n  archive_dir: \(long)\n")
        let value = try XCTUnwrap(sections.fileOnly.first?.settings.first?.value)
        XCTAssertLessThanOrEqual(value.count, 60)
        XCTAssertTrue(value.hasSuffix("…"))
        XCTAssertNil(value.unicodeScalars.first { CharacterSet.controlCharacters.contains($0) })
    }

    func testEmptyNullAndListValuesRead() throws {
        let yaml = """
        sheets:
          only:
            - Summary
            - Devices
          skip: []
        html:
          history_file: ""
          track_history:
        """
        XCTAssertEqual(summary(try build(yaml)), [
            "sheets: sheets.only=Summary, Devices, sheets.skip=(empty)",
            "html: html.history_file=(empty), html.track_history=(empty)",
        ])
    }

    func testARepeatedKeyShowsTheValueTheAppReads() throws {
        let sections = try build("jamf_cli:\n  data_dir: first\n  data_dir: second\n")
        XCTAssertEqual(summary(sections), ["jamf_cli: jamf_cli.data_dir=second"])
        XCTAssertEqual(sections.skipped.count, 1)
    }

    func testAValueOfTheWrongShapeIsNotListed() throws {
        let yaml = "thresholds: 5\ncolumns:\n  - a\n  - b\njamf_cli:\n  data_dir:\n    x: 1\n"
        XCTAssertEqual(summary(try build(yaml)), [])
    }

    // MARK: - Limits and the unreadable cases

    func testLongListsEndInACount() throws {
        var yaml = "compliance:\n  baselines:\n"
        for index in 0..<80 {
            yaml += "    - name: B\(index)\n      failures_count_column: F\(index)\n"
                + "      rule_count: \(index)\n"
        }
        for index in 0..<60 { yaml += "bogus_\(index): 1\n" }
        let sections = try build(yaml)
        XCTAssertEqual(sections.fileOnly.flatMap(\.settings).count, ConfigFileSections.settingCap)
        XCTAssertEqual(sections.omittedSettings, 240 - ConfigFileSections.settingCap)
        XCTAssertEqual(sections.unknown.count, ConfigFileSections.noteCap)
        XCTAssertEqual(sections.omittedUnknown, 60 - ConfigFileSections.noteCap)
    }

    /// Two keys cut to the same displayed text list under one key path, so a row cannot be
    /// identified by it.
    func testTwoLongUnknownKeysCanShareADisplayedPath() throws {
        let stem = String(repeating: "k", count: 70)
        let sections = try build("columns:\n  \(stem)a: 1\n  \(stem)b: 2\n")
        XCTAssertEqual(sections.unknown.count, 2)
        XCTAssertEqual(Set(sections.unknown.map(\.keyPath)).count, 1)
    }

    func testAFileThatIsNotAMappingThrows() {
        XCTAssertThrowsError(try build("- a\n- b\n"))
    }

    func testAnEmptyFileHasNothingToShow() throws {
        XCTAssertTrue(try build("").isEmpty)
        XCTAssertEqual(
            ConfigFileSections.nothingToShow,
            "Everything in config.yaml is editable on the other tabs.")
    }

    // MARK: - Reading the file

    private func tempFile(_ text: String?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-fromfile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.yaml")
        if let text { try text.write(to: url, atomically: true, encoding: .utf8) }
        return url
    }

    func testReadReturnsTheSectionsForAFile() throws {
        let url = try tempFile("jamf_cli:\n  data_dir: snaps\n")
        guard case .sections(let sections) = ConfigFileReading.read(at: url) else {
            return XCTFail("expected sections")
        }
        XCTAssertEqual(summary(sections), ["jamf_cli: jamf_cli.data_dir=snaps"])
    }

    func testReadSaysWhyThereIsNothingToList() throws {
        XCTAssertEqual(
            ConfigFileReading.read(at: try tempFile(nil)),
            .unavailable("config.yaml does not exist yet. Saving from another tab creates it."))
        XCTAssertEqual(
            ConfigFileReading.read(at: nil),
            .unavailable("The workspace folder was not found."))
        XCTAssertEqual(
            ConfigFileReading.read(at: try tempFile("- a\n")),
            .unavailable("config.yaml must contain a top-level YAML mapping."))
    }

    /// Reveal needs the file to exist, not to be readable as a mapping.
    func testRevealIsOfferedForAnyFileThatExists() throws {
        XCTAssertTrue(ConfigFileReading.canReveal(at: try tempFile("jamf_cli:\n  data_dir: s\n")))
        XCTAssertTrue(ConfigFileReading.canReveal(at: try tempFile("- a\n")))
        XCTAssertFalse(ConfigFileReading.canReveal(at: try tempFile(nil)))
        XCTAssertFalse(ConfigFileReading.canReveal(at: nil))
        XCTAssertFalse(ConfigFileReading.canReveal(
            at: try tempFile("a: 1\n"), demoMode: true))
    }

    func testDemoModeReadsNoFile() throws {
        let url = try tempFile("jamf_cli:\n  data_dir: snaps\n")
        XCTAssertEqual(
            ConfigFileReading.read(at: url, demoMode: true), .sections(ConfigFileSections()))
        XCTAssertTrue(ConfigFileSections().isEmpty)
    }
}
