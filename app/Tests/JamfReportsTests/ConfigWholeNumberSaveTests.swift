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
