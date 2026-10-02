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

    /// The old lookup also took yes, 1 and on, which the decoder's boolean rule does not.
    func testAllowAbsolutePathsNoLongerOptsInForYesOneOrOn() throws {
        for value in ["yes", "1", "on", "false", "\"\""] {
            XCTAssertFalse(try optsIn("output:\n  allow_absolute_paths: \(value)\n"), value)
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
            .appendingPathComponent(".jrc-read-outside-\(UUID().uuidString)", isDirectory: true)
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
