import XCTest
@testable import JamfReports

/// A cleared or mistyped number on the Config screen was written as text
/// (`stale_device_days: ""`), which the engine cannot decode, so every collect, report and
/// scheduled run failed on every Mac sharing the workspace.
final class ConfigWholeNumberSaveTests: XCTestCase {

    private func workspace() throws -> (root: URL, profile: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JamfReportsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, "numbers-\(UUID().uuidString.lowercased())")
    }

    private func configText(_ ws: (root: URL, profile: String)) throws -> String {
        try String(contentsOf: ConfigService.configURL(for: ws.profile, workspaceRoot: ws.root),
                   encoding: .utf8)
    }

    private func save(
        _ ws: (root: URL, profile: String), _ edit: (inout ConfigState) -> Void
    ) throws {
        var state = ConfigState.defaultState
        edit(&state)
        _ = try ConfigService.save(
            profile: ws.profile, state: state, existingDocument: nil, workspaceRoot: ws.root)
    }

    func testABlankNumberIsLeftOutAndTheFileStillDecodes() throws {
        let ws = try workspace()
        try save(ws) {
            $0.staleDeviceDays = ""
            $0.keepLatestRuns = "  "
            $0.certWarningDays = "45"
        }
        let text = try configText(ws)
        XCTAssertFalse(text.contains("stale_device_days"), text)
        XCTAssertFalse(text.contains("keep_latest_runs"), text)

        let config = try ConfigLoader.loadFromString(text)
        XCTAssertEqual(config.staleRule.days, 30, "a cleared field falls back to the default")
        XCTAssertEqual(config.thresholds?.certWarningDays, 45)
    }

    func testTextThatIsNotAWholeNumberIsRefusedAndNothingIsWritten() throws {
        let ws = try workspace()
        try save(ws) { $0.staleDeviceDays = "21" }
        let before = try configText(ws)

        for typed in ["abc", "30.5", "30 days"] {
            XCTAssertThrowsError(try save(ws) { $0.staleDeviceDays = typed }) { error in
                guard case ConfigService.ConfigError.notAWholeNumber(let key, let value) = error
                else { return XCTFail("unexpected error \(error)") }
                XCTAssertEqual(key, "thresholds.stale_device_days")
                XCTAssertEqual(value, typed)
                XCTAssertTrue(
                    (error as? LocalizedError)?.errorDescription?.contains("nothing was saved")
                        == true)
            }
            XCTAssertEqual(try configText(ws), before, "\(typed) left the file as it was")
        }
        XCTAssertThrowsError(try save(ws) { $0.keepLatestRuns = "ten" })
    }

    /// A count that is not a whole number used to fail the decode of the whole config.yaml;
    /// it now costs only that count, which takes its default.
    func testANonNumberCountReadsAsItsDefaultAndTheRestStillDecodes() throws {
        let config = try ConfigLoader.loadFromString("""
        thresholds:
          stale_device_days: 30.0
          checkin_overdue_days: "30 days"
          warning_disk_percent: true
          critical_disk_percent: "95"
          cert_warning_days: 45
        output:
          keep_latest_runs: ten
          output_dir: Reports
        """)
        let thresholds = try XCTUnwrap(config.thresholds)
        XCTAssertNil(thresholds.staleDeviceDays)
        XCTAssertEqual(thresholds.resolvedStaleDays, 30)
        XCTAssertEqual(thresholds.resolvedCheckinOverdueDays, 7)
        XCTAssertEqual(thresholds.resolvedWarningDisk, 80)
        XCTAssertEqual(thresholds.criticalDiskPercent, 95, "a quoted whole number still reads")
        XCTAssertEqual(thresholds.certWarningDays, 45)
        XCTAssertEqual(config.output?.resolvedKeepLatestRuns, 10)
        XCTAssertEqual(config.output?.outputDir, "Reports")
    }

    func testConfigDoctorNamesEachCountItReplaced() throws {
        let yaml = """
        thresholds:
          stale_device_days: 30.0
          critical_disk_percent: "95"
          warning_disk_percent: true
          cert_warning_days: 45
        output:
          keep_latest_runs: ten
        """
        let rows = ConfigDoctorService.valueRows(
            try ConfigLoader.loadFromString(yaml), raw: try ConfigLoader.rawMapping(fromYAML: yaml),
            profile: "ws")
            .filter { $0.id.hasSuffix(".number") }
        XCTAssertEqual(rows.map(\.title).sorted(),
                       ["output.keep_latest_runs", "thresholds.stale_device_days",
                        "thresholds.warning_disk_percent"])
        XCTAssertTrue(rows.contains { $0.detail.contains("The app uses 30") })
    }

    /// A bad count already in the file must not block saving something else, such as the
    /// EA walkthrough's Adopt or a column re-scaffold; it is left exactly as typed.
    func testABadCountTheFileAlreadyHoldsDoesNotBlockAnotherSave() throws {
        let ws = try workspace()
        let url = try ConfigService.configURL(for: ws.profile, workspaceRoot: ws.root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "thresholds:\n  cert_warning_days: ninety\n".write(
            to: url, atomically: true, encoding: .utf8)

        let loaded = try ConfigService.load(profile: ws.profile, workspaceRoot: ws.root)
        var state = loaded.state
        XCTAssertEqual(state.certWarningDays, "ninety")
        state.staleDeviceDays = "21"
        _ = try ConfigService.save(
            profile: ws.profile, state: state, existingDocument: loaded.document,
            workspaceRoot: ws.root)

        let text = try configText(ws)
        XCTAssertTrue(text.contains("cert_warning_days: ninety"), text)
        XCTAssertTrue(text.contains("stale_device_days: 21"), text)
        XCTAssertEqual(try ConfigLoader.loadFromString(text).thresholds?.staleDeviceDays, 21)
    }

    func testAPastedNewlineAroundANumberIsAccepted() throws {
        let ws = try workspace()
        try save(ws) { $0.staleDeviceDays = "21\n" }
        XCTAssertTrue(try configText(ws).contains("stale_device_days: 21"))
    }

    func testEveryNumberFieldTheScreenWritesIsChecked() {
        var state = ConfigState.defaultState
        XCTAssertNil(ConfigService.notAWholeNumber(in: state))
        for index in ConfigService.wholeNumberFields(state).indices {
            state = ConfigState.defaultState
            switch index {
            case 0: state.staleDeviceDays = "x"
            case 1: state.checkinOverdueDays = "x"
            case 2: state.warningDiskPercent = "x"
            case 3: state.criticalDiskPercent = "x"
            case 4: state.certWarningDays = "x"
            case 5: state.profileErrorWarning = "x"
            default: state.keepLatestRuns = "x"
            }
            XCTAssertNotNil(ConfigService.notAWholeNumber(in: state), "field \(index)")
        }
    }
}
