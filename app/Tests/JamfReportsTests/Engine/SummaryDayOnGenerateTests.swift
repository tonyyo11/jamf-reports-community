import Foundation
import XCTest
@testable import JamfReports

/// A run that crosses midnight dates its summary by its start on every path: `collect` dated
/// it, and the `generate` that follows in the same run must find that file, not add the next
/// day's from cache.
final class SummaryDayOnGenerateTests: XCTestCase {
    private var root: URL!
    private var workspace: URL { root.appendingPathComponent("shared", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-summary-day-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func summaryNames() -> [String] {
        let walker = FileManager.default.enumerator(atPath: workspace.path)
        return (walker?.allObjects as? [String] ?? [])
            .map { ($0 as NSString).lastPathComponent }
            .filter { $0.hasPrefix("summary_") && $0.hasSuffix(".json") }.sorted()
    }

    func testAGenerateAfterMidnightKeepsTheSummaryTheCollectDated() async throws {
        let configURL = workspace.appendingPathComponent("config.yaml")
        try "charts:\n  enabled: false\n".write(to: configURL, atomically: true, encoding: .utf8)
        let dataDir = workspace.appendingPathComponent("jamf-cli-data", isDirectory: true)
        try GoldenFleetWorkspace.writeJSON(
            GoldenFleetWorkspace.securitySummaryPayload(
                total: 10, filevault: 10, sip: 10, firewall: 10, gatekeeper: 10),
            to: dataDir.appendingPathComponent("security", isDirectory: true)
                .appendingPathComponent(
                    "security_\(GoldenFleetClock.stamp(GoldenFleetClock.anchorNoon())).json"))
        let config = try ConfigLoader.load(from: configURL)
        let engine = ReportEngine(
            config: config, dataDir: dataDir, workspace: WorkspaceID("shared"))
        // 23:59:30 on the start day; the generate below runs after 00:00:00 the next day.
        let start = try XCTUnwrap(Calendar.current.date(
            bySettingHour: 23, minute: 59, second: 30, of: .testNoon))
        let summaries = try XCTUnwrap(try WorkspacePaths.summariesDir(for: "shared"))
        XCTAssertEqual(engine.emitSummaryJSON(summariesDir: summaries, day: start), .wrote)

        try await engine.generate(
            outputURL: workspace.appendingPathComponent("Generated Reports/r.xlsx"),
            locateJamfCLI: { nil }, now: start)

        let day = SummaryJSONParser.dateFormatter.string(from: start)
        XCTAssertEqual(summaryNames(), ["summary_\(day).json"])
    }
}
