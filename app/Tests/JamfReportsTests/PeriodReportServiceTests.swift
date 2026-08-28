import XCTest
@testable import JamfReports

final class PeriodReportServiceTests: XCTestCase {
    private var root: URL!
    private let profile = "acme-prod"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-period-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }
    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func d(_ s: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f.date(from: s)!
    }

    private func writeSummary(_ date: String, total: Int, fv: Double) throws {
        let dir = try WorkspacePaths.summariesDir(for: profile)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        {"date":"\(date)","totalDevices":\(total),"fileVaultPct":\(fv),"source":"test"}
        """.write(to: dir.appendingPathComponent("summary_\(date).json"),
                  atomically: true, encoding: .utf8)
    }

    func testCatalogOffersFleetMetricsFromWrittenSummaries() throws {
        try writeSummary("2026-04-01", total: 600, fv: 96)
        try writeSummary("2026-06-30", total: 662, fv: 98)
        let ids = PeriodReportService.catalog(profile: profile).map(\.id)
        XCTAssertTrue(ids.contains("totalDevices"))
        XCTAssertTrue(ids.contains("fileVaultPct"))
    }

    func testGenerateWritesAWorkbookIntoTheOutputDirectory() throws {
        try writeSummary("2026-04-01", total: 600, fv: 96)
        try writeSummary("2026-06-30", total: 662, fv: 98)
        let url = try PeriodReportService.generate(
            profile: profile,
            kind: .explicit(start: d("2026-04-01"), end: d("2026-06-30")),
            metricIDs: ["totalDevices", "fileVaultPct"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(url.lastPathComponent.hasPrefix("period-report-"),
                      "got \(url.lastPathComponent)")
    }

    /// A period with no summaries has nothing honest to report.
    func testGenerateThrowsWhenNoDataFallsInThePeriod() throws {
        try writeSummary("2020-01-01", total: 1, fv: 1)
        XCTAssertThrowsError(try PeriodReportService.generate(
            profile: profile,
            kind: .explicit(start: d("2026-04-01"), end: d("2026-06-30")),
            metricIDs: ["totalDevices"]))
    }

    func testCatalogOnAnEmptyWorkspaceDoesNotCrash() {
        XCTAssertFalse(PeriodReportService.catalog(profile: "acme-empty").isEmpty,
                       "totalDevices is always offered")
    }

    /// Extension attributes are opt-in: an empty selection means fleet metrics
    /// only, never "everything including whatever an EA happens to contain".
    func testEmptySelectionYieldsFleetMetricsOnlyNotEverything() {
        let ids = PeriodReportService.defaultSelection(
            from: [PeriodMetric(id: "totalDevices", label: "Managed devices",
                                unit: .count, source: .fleet),
                   PeriodMetric(id: "ea:Widget Status", label: "Widget Status",
                                unit: .distribution,
                                source: .extensionAttribute(name: "Widget Status", match: nil))])
        XCTAssertEqual(ids, ["totalDevices"],
                       "EA metrics must not be selected by default")
    }

    /// A saved selection naming a metric that is no longer offered is dropped
    /// silently rather than surfaced as an error.
    func testStaleSelectionEntriesAreDropped() {
        let available = [PeriodMetric(id: "totalDevices", label: "Managed devices",
                                      unit: .count, source: .fleet)]
        XCTAssertEqual(
            PeriodReportService.pruneSelection(["totalDevices", "ea:Gone"], available: available),
            ["totalDevices"])
    }
}
