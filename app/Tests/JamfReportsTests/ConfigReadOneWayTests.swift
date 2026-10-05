import XCTest
@testable import JamfReports

/// Every reader of config.yaml reads a value the way the report engine's decoder does.
final class ConfigReadOneWayTests: XCTestCase {

    private let fileManager = FileManager.default

    // MARK: - Byte-order mark

    /// `YAMLCodec.decode` and `ConfigLoader.loadFromString` take text from any caller, and
    /// `String(decoding:as:)` keeps a byte-order mark.
    func testAByteOrderMarkIsNotPartOfTheFirstKey() throws {
        let text = "\u{FEFF}thresholds:\n  stale_device_days: 45\n"
        let root = try YAMLCodec.decode(text).root.mapping
        XCTAssertEqual(root?.entries.first?.key, "thresholds")
        XCTAssertEqual(try ConfigLoader.loadFromString(text).thresholds?.staleDeviceDays, 45)
        let bytes = Data([0xEF, 0xBB, 0xBF] + Array("thresholds:\n  a: 1\n".utf8))
        XCTAssertEqual(try YAMLCodec.decode(String(decoding: bytes, as: UTF8.self))
            .root.mapping?.entries.first?.key, "thresholds")
    }

    /// Through a file: Foundation's UTF-8 file read already drops the mark, so this passed
    /// before the codec stripped it too.
    func testAConfigFileThatStartsWithAByteOrderMarkLoads() throws {
        let dir = fileManager.temporaryDirectory
            .appendingPathComponent("jrc-bom-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.yaml")
        try Data([0xEF, 0xBB, 0xBF] + Array("thresholds:\n  stale_device_days: 45\n".utf8))
            .write(to: url)
        XCTAssertEqual(try ConfigLoader.load(from: url).thresholds?.staleDeviceDays, 45)
    }

    // MARK: - A key set twice

    private static let repeatedKeys = """
        thresholds:
          stale_device_days: 10
          stale_device_days: 45
        output:
          output_dir: First Reports
        output:
          output_dir: Second Reports
        """

    func testEveryReaderTakesTheLastOfARepeatedKey() throws {
        try withWorkspace(config: Self.repeatedKeys) { root, profile in
            let url = try ConfigService.configURL(for: profile, workspaceRoot: root)
            let engine = try ConfigLoader.load(from: url)
            XCTAssertEqual(engine.thresholds?.staleDeviceDays, 45)
            XCTAssertEqual(engine.output?.outputDir, "Second Reports")

            let screen = try ConfigService.load(profile: profile, workspaceRoot: root)
            XCTAssertEqual(screen.state.staleDeviceDays, "45")
            XCTAssertEqual(screen.state.outputDir, "Second Reports")
            XCTAssertEqual(try WorkspacePaths.outputDir(for: profile).lastPathComponent,
                           "Second Reports")
            XCTAssertEqual(screen.document.parseNotes.map(\.kind), [
                .duplicateKey("stale_device_days", readLine: 3),
                .duplicateKey("output", readLine: 6),
            ])
        }
    }

    /// A Config screen edit lands on the occurrence every reader takes.
    func testASaveChangesTheRepeatedKeyThatIsRead() throws {
        try withWorkspace(config: Self.repeatedKeys) { root, profile in
            var state = try ConfigService.load(profile: profile, workspaceRoot: root).state
            state.staleDeviceDays = "60"
            state.outputDir = "Edited Reports"
            _ = try ConfigService.save(
                profile: profile, state: state, existingDocument: nil, workspaceRoot: root)
            let url = try ConfigService.configURL(for: profile, workspaceRoot: root)
            let engine = try ConfigLoader.load(from: url)
            XCTAssertEqual(engine.thresholds?.staleDeviceDays, 60)
            XCTAssertEqual(engine.output?.outputDir, "Edited Reports")
            let screen = try ConfigService.load(profile: profile, workspaceRoot: root).state
            XCTAssertEqual(screen.staleDeviceDays, "60")
            XCTAssertEqual(screen.outputDir, "Edited Reports")
        }
    }

    // MARK: - What a Config screen save keeps

    /// The earlier copy of a repeated block, which no reader takes, stays as typed.
    func testASaveRewritesOnlyTheLastCopyOfARepeatedBlock() throws {
        let typed = """
            thresholds:
              stale_device_days: 10
            output:
              output_dir: Reports
            thresholds:
              stale_device_days: 45
            """
        let saved = try savedText(typed) { $0.staleDeviceDays = "60" }
        XCTAssertTrue(saved.text.hasPrefix(
            "thresholds:\n  stale_device_days: 10\noutput:\n"), saved.text)
        XCTAssertEqual(saved.engine.thresholds?.staleDeviceDays, 60)
    }

    /// Known loss, left to Task 4 (backup and banner): a line the reader skipped inside a block
    /// the Config screen edits is gone after a save, because that block is written anew.
    func testKnownLossASkippedLineInsideABlockTheScreenEditsIsDroppedOnSave() throws {
        let saved = try savedText("thresholds:\n  stale_device_days: 30\n  just some words\n")
        XCTAssertFalse(saved.text.contains("just some words"), saved.text)
        XCTAssertEqual(saved.engine.thresholds?.staleDeviceDays, 30)
    }

    func testASkippedLineOutsideTheBlocksTheScreenEditsSurvivesASave() throws {
        let saved = try savedText("html:\n  track_history: false\n  just some words\n")
        XCTAssertTrue(saved.text.hasPrefix("html:\n  track_history: false\n  just some words\n"),
                      saved.text)
    }

    /// A tab-indented line reads as a top-level key, and a save keeps it as typed.
    func testATabIndentedLineSurvivesASave() throws {
        let saved = try savedText("thresholds:\n  stale_device_days: 30\n\tcert_warning_days: 60\n")
        XCTAssertTrue(saved.text.contains("\n\tcert_warning_days: 60\n"), saved.text)
        XCTAssertEqual(saved.engine.thresholds?.staleDeviceDays, 30)
    }

    // MARK: - html.track_history and html.history_file (HtmlReport)

    /// Each of these turned history off under the line scanner HtmlReport used.
    func testTrackHistoryIsReadWithTheDecodersBooleanRule() throws {
        for yaml in [
            "html:\n  track_history: true # keep a trend\n",
            "html:\n  track_history: True\n",
            "html:\n  track_history: \"true\"\n",
            "html:\r\n  track_history: true\r\n",
            "html: {track_history: true}\n",
        ] {
            XCTAssertTrue(try historyFile(yaml) != nil, yaml.debugDescription)
        }
        for yaml in ["html:\n  track_history: yes\n", "html:\n  track_history: false\n", "a: 1\n"] {
            XCTAssertNil(try historyFile(yaml), yaml.debugDescription)
        }
    }

    /// The scanner kept the comment as part of the file name.
    func testHistoryFileIsReadWithoutATrailingComment() throws {
        let yaml = "html:\n  track_history: true\n  history_file: trend.json # beside the report\n"
        XCTAssertEqual(try historyFile(yaml), "trend.json")
    }

    // MARK: - thresholds.stale_device_days (Devices screen)

    /// A Mac last seen 40 days ago is stale at the default 30 and not at 45, so `stale` shows
    /// which threshold the Devices screen read.
    func testTheDevicesScreenReadsStaleDeviceDaysWhereTheScannerFellBackTo30() throws {
        for yaml in [
            "thresholds: # how old is stale\n  stale_device_days: 45\n",
            "thresholds: {stale_device_days: 45}\n",
            "thresholds:\n  stale_device_days: 45 # days\n",
        ] {
            XCTAssertEqual(try devicesScreenCallsStale(yaml), false, yaml)
        }
        XCTAssertEqual(try devicesScreenCallsStale("other: 1\n"), true)
    }

    /// The decoder rejects a quoted number for this key (the whole file fails to load, which
    /// the Config screen and the Doctor report), so the Devices screen no longer takes it.
    func testTheDevicesScreenDoesNotTakeAQuotedStaleDeviceDays() throws {
        XCTAssertEqual(try devicesScreenCallsStale("thresholds:\n  stale_device_days: \"45\"\n"),
                       true)
        XCTAssertThrowsError(try ConfigLoader.loadFromString(
            "thresholds:\n  stale_device_days: \"45\"\n"))
    }

    // MARK: - output.allow_absolute_paths (WorkspacePaths)

    func testAllowAbsolutePathsOptsInForTrueAsTheDecoderReadsIt() throws {
        for value in ["true", "True", "\"true\"", "true # reports go to the share"] {
            XCTAssertTrue(try optsIn("output:\n  allow_absolute_paths: \(value)\n"), value)
        }
        XCTAssertTrue(try optsIn("output: {allow_absolute_paths: true}\n"))
    }

    /// The opt-in has always taken yes, on and 1 as well as true; a non-true spelling is a
    /// Doctor suggestion, not a refusal.
    func testAllowAbsolutePathsOptsInForYes() throws {
        for value in ["yes", "Yes", "YES", "\"yes\"", "'yes'"] {
            XCTAssertTrue(try optsIn("output:\n  allow_absolute_paths: \(value)\n"), value)
        }
    }

    func testAllowAbsolutePathsOptsInForOn() throws {
        for value in ["on", "On", "ON", "\"on\""] {
            XCTAssertTrue(try optsIn("output:\n  allow_absolute_paths: \(value)\n"), value)
        }
    }

    func testAllowAbsolutePathsOptsInForOne() throws {
        for value in ["1", "\"1\""] {
            XCTAssertTrue(try optsIn("output:\n  allow_absolute_paths: \(value)\n"), value)
        }
    }

    func testAllowAbsolutePathsDoesNotOptInForAnythingElse() throws {
        for value in ["false", "no", "off", "0", "2", "maybe", "\"\""] {
            XCTAssertFalse(try optsIn("output:\n  allow_absolute_paths: \(value)\n"), value)
        }
    }

    // MARK: - Path keys

    /// A folder key holding a number, true or a quoted null, which the decoder does not take as
    /// a folder name, uses the default folder. Before 1f647944, WorkspacePaths and the Devices
    /// screen used a folder named `2024` or `null`.
    func testAPathKeyThatIsNotTextUsesTheDefaultFolder() throws {
        for value in ["2024", "\"null\"", "true"] {
            let yaml = "output:\n  output_dir: \(value)\njamf_cli:\n  data_dir: \(value)\n"
            try withWorkspace(config: yaml) { root, profile in
                XCTAssertEqual(try WorkspacePaths.outputDir(for: profile).lastPathComponent,
                               "Generated Reports", value)
                XCTAssertEqual(try WorkspacePaths.dataDir(for: profile).lastPathComponent,
                               "jamf-cli-data", value)
                let reports = root.appendingPathComponent("\(profile)/Generated Reports",
                                                          isDirectory: true)
                try fileManager.createDirectory(at: reports, withIntermediateDirectories: true)
                try "Computer Name,Serial Number\nExample Mac,EX0001\n".write(
                    to: reports.appendingPathComponent("automation_inventory_example.csv"),
                    atomically: true, encoding: .utf8)
                let sources = DeviceInventoryService.load(profile: profile, demoMode: false)
                    .sourceFiles
                XCTAssertTrue(sources.contains {
                    $0.hasSuffix("Generated Reports/automation_inventory_example.csv")
                }, "\(value): \(sources)")
            }
        }
    }

    // MARK: - A quoted true, false or null

    /// A text key whose value is the word true stays text, instead of failing the whole file.
    func testAQuotedBooleanWordStaysTextForATextKey() throws {
        let config = try ConfigLoader.loadFromString("""
            custom_eas:
              - name: Example Flag
                column: Example - Flag
                type: boolean
                true_value: "true"
            security_agents:
              - name: First Agent
                column: First Agent - Status
                connected_value: Running
              - name: Second Agent
                column: Second Agent - Running
                connected_value: 'False'
            """)
        XCTAssertEqual(config.customEas?.first?.trueValue, "true")
        XCTAssertEqual(config.securityAgents?.last?.connectedValue, "False")
    }

    /// An unquoted number in a text key reads as the number's text, instead of failing the
    /// whole file; a number key still reads a number.
    func testAnUnquotedNumberInATextKeyReadsAsText() throws {
        let config = try ConfigLoader.loadFromString("""
            jamf_cli:
              profile: 2026
            thresholds:
              stale_device_days: 45
            custom_eas:
              - name: Build Flag
                column: Build - Flag
                type: boolean
                true_value: 1
              - name: OS Major
                column: OS - Major
                type: version
                current_versions: [26, "15"]
            """)
        XCTAssertEqual(config.jamfCli?.profile, "2026")
        XCTAssertEqual(config.customEas?.first?.trueValue, "1")
        XCTAssertEqual(config.customEas?.last?.currentVersions, ["26", "15"])
        XCTAssertEqual(config.thresholds?.staleDeviceDays, 45)
    }

    /// A boolean key still takes a quoted boolean; an unquoted one in a text key still fails.
    func testBooleanKeysStillTakeAQuotedBoolean() throws {
        let config = try ConfigLoader.loadFromString(
            "compliance:\n  enabled: \"true\"\noutput:\n  archive_enabled: 'FALSE'\n")
        XCTAssertEqual(config.compliance?.enabled, true)
        XCTAssertEqual(config.output?.archiveEnabled, false)
        XCTAssertThrowsError(try ConfigLoader.loadFromString(
            "custom_eas:\n  - name: A\n    column: B\n    type: boolean\n    true_value: true\n"))
    }

    /// The Config screen writes `true_value: "true"` for a boolean EA expecting the word true.
    func testABooleanEASavedFromTheConfigScreenStillLoads() throws {
        try withWorkspace(config: "output:\n  output_dir: Reports\n") { root, profile in
            var state = try ConfigService.load(profile: profile, workspaceRoot: root).state
            state.customEAs = [ConfigCustomEA(
                name: "Example Flag", column: "Example - Flag", type: "boolean",
                trueValue: "true", warningThreshold: "", criticalThreshold: "",
                currentVersions: [], warningDays: "")]
            _ = try ConfigService.save(
                profile: profile, state: state, existingDocument: nil, workspaceRoot: root)
            let url = try ConfigService.configURL(for: profile, workspaceRoot: root)
            XCTAssertTrue(try String(contentsOf: url, encoding: .utf8)
                .contains("true_value: \"true\""))
            XCTAssertEqual(try ConfigLoader.load(from: url).customEas?.first?.trueValue, "true")
        }
    }

    // MARK: - Helpers

    /// Builds the history section from a workspace whose config.yaml is `yaml`; returns the
    /// history file it wrote, or nil when history is off.
    private func historyFile(_ yaml: String) throws -> String? {
        let dir = fileManager.temporaryDirectory
            .appendingPathComponent("jrc-html-\(UUID().uuidString)", isDirectory: true)
        let dataDir = dir.appendingPathComponent("jamf-cli-data", isDirectory: true)
        try fileManager.createDirectory(at: dataDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: dir) }
        try yaml.write(to: dir.appendingPathComponent("config.yaml"), atomically: true,
                       encoding: .utf8)
        let report = HtmlReport(config: ReportConfig().withDefaults(), dataDir: dataDir)
        let html = report.buildHistorySection(
            security: [], outputURL: dir.appendingPathComponent("report.html"))
        guard !html.isEmpty else { return nil }
        let written = try fileManager.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") }
        XCTAssertEqual(written.count, 1)
        return written.first
    }

    /// Loads `typed` on the Config screen, applies `edit`, saves, and returns the file and what
    /// the engine reads from it.
    private func savedText(
        _ typed: String, edit: (inout ConfigState) -> Void = { _ in }
    ) throws -> (text: String, engine: ReportConfig) {
        var result: (text: String, engine: ReportConfig)?
        try withWorkspace(config: typed) { root, profile in
            var state = try ConfigService.load(profile: profile, workspaceRoot: root).state
            edit(&state)
            _ = try ConfigService.save(
                profile: profile, state: state, existingDocument: nil, workspaceRoot: root)
            let url = try ConfigService.configURL(for: profile, workspaceRoot: root)
            let text = try String(contentsOf: url, encoding: .utf8)
            result = (text, try ConfigLoader.load(from: url))
        }
        return try XCTUnwrap(result)
    }

    /// Whether the Devices screen marks a Mac last seen 40 days ago as stale.
    private func devicesScreenCallsStale(_ yaml: String) throws -> Bool? {
        var stale: Bool?
        try withWorkspace(config: yaml) { root, profile in
            let kind = root.appendingPathComponent("\(profile)/jamf-cli-data/device-compliance",
                                                   isDirectory: true)
            try fileManager.createDirectory(at: kind, withIntermediateDirectories: true)
            let row = #"[{"days_since_contact": "40", "name": "Example Mac", "serial": "EX0001", "#
                + #""stale": false}]"#
            try row.write(to: kind.appendingPathComponent("device-compliance_20260901T090000.json"),
                          atomically: true, encoding: .utf8)
            let devices = DeviceInventoryService.load(profile: profile, demoMode: false).devices
            XCTAssertEqual(devices.count, 1)
            stale = devices.first?.stale
        }
        return stale
    }

    /// Whether WorkspacePaths accepts an output folder outside the workspace.
    private func optsIn(_ yaml: String) throws -> Bool {
        let outside = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("jrc-read-outside-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: outside) }
        var accepted = false
        let config = yaml
            .replacingOccurrences(of: "output:\n", with: "output:\n  output_dir: \(outside.path)\n")
            .replacingOccurrences(of: "output: {", with: "output: {output_dir: \(outside.path), ")
        try withWorkspace(config: config) { _, profile in
            do {
                accepted = try WorkspacePaths.outputDir(for: profile).standardizedFileURL.path
                    == outside.standardizedFileURL.path
            } catch WorkspacePaths.PathError.disallowedAbsolutePath {
                accepted = false
            }
        }
        return accepted
    }

    /// A temp workspaces root holding one workspace with `config`; `JRC_TEST_WORKSPACES_ROOT`
    /// points at it for the duration and is then restored.
    private func withWorkspace(
        config: String, _ body: (URL, String) throws -> Void
    ) throws {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("jrc-read-\(UUID().uuidString)", isDirectory: true)
        let profile = "readers"
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        try config.write(
            to: workspace.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        let previous = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            if let previous {
                setenv("JRC_TEST_WORKSPACES_ROOT", previous, 1)
            } else {
                unsetenv("JRC_TEST_WORKSPACES_ROOT")
            }
        }
        try body(root, profile)
    }
}
