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

    /// A bare `[EAResultRow]` `ea-results` snapshot using the `device`/`ea_name`/
    /// `value` shape, stamped with a canonical `CloudStorage.snapshotTimestamp`
    /// filename so `PeriodEAReader.load` can order it.
    private func writeEAResults(_ filename: String, ea: String, values: [String]) throws {
        try writeEAResults(filename, attributes: [(ea: ea, values: values)])
    }

    /// Multi-attribute overload: one snapshot file carrying several EAs, the
    /// shape a real `ea-results` collect actually produces.
    private func writeEAResults(
        _ filename: String, attributes: [(ea: String, values: [String])]
    ) throws {
        let dir = try WorkspacePaths.dataDir(for: profile)
            .appendingPathComponent("ea-results", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var objs: [String] = []
        for (ea, values) in attributes {
            objs += values.enumerated().map { i, v in
                #"{"device":"mac-\#(i)","ea_name":"\#(ea)","value":"\#(v)"}"#
            }
        }
        let json = "[" + objs.joined(separator: ",") + "]"
        try json.data(using: .utf8)!.write(to: dir.appendingPathComponent(filename))
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

    // MARK: - Cardinality at the period boundaries

    /// An attribute can be identifier-shaped early in a window and settle into
    /// a small set of statuses by the end (or the reverse). Checking only the
    /// newest snapshot — "now" — would miss the earlier shape entirely, so the
    /// resolved period's start AND end boundaries must both be checked.
    func testCardinalityFlagsAnEAThatIsIdentifierShapedOnlyAtTheStartBoundary() throws {
        let identifierValues = (0..<10).map { "SN-\($0)-UNIQUE" }
        let statusValues = Array(repeating: "On", count: 5) + Array(repeating: "Off", count: 5)
        // Comfortably before the start boundary, so `load(on:)` finds it there
        // and NOT at the end boundary.
        try writeEAResults("ea-results_20260331T230000.json",
                           ea: "SerialNumber", values: identifierValues)
        // Comfortably before the end boundary (and after the start one), so it
        // is what both "on the end boundary" and "no period at all" resolve to.
        try writeEAResults("ea-results_20260629T230000.json",
                           ea: "SerialNumber", values: statusValues)

        let period = try XCTUnwrap(ReportPeriod.resolve(
            kind: .explicit(start: d("2026-04-01"), end: d("2026-06-30")),
            availableDates: [d("2026-04-01"), d("2026-06-30")], now: d("2026-07-15")))

        // Without a resolved period, only the newest snapshot is checked, and
        // it is status-shaped — not flagged.
        let withoutPeriod = PeriodReportService.cardinality(profile: profile, ea: "SerialNumber")
        XCTAssertFalse(PeriodMetricCatalog.looksLikeIdentifier(
            distinct: withoutPeriod.distinct, devices: withoutPeriod.devices))

        // With the resolved period, the identifier-shaped start boundary is
        // still caught even though the end boundary looks like a status.
        let withPeriod = PeriodReportService.cardinality(
            profile: profile, ea: "SerialNumber", period: period)
        XCTAssertTrue(PeriodMetricCatalog.looksLikeIdentifier(
            distinct: withPeriod.distinct, devices: withPeriod.devices))
    }

    /// `looksLikeIdentifier` requires a minimum sample before its ratio
    /// counts at all, so a tiny, coincidentally all-distinct boundary (3
    /// devices, 3 values, ratio 1.0) must not outrank a well-sampled boundary
    /// that actually clears the identifier threshold (200 devices, 190
    /// values, ratio 0.95) just because its ratio happens to be lower.
    func testCardinalityDoesNotLetAnUnderSampledBoundaryOutrankAFlaggedOne() throws {
        let tinyAllDistinctValues = ["V1", "V2", "V3"]
        let wellSampledIdentifierValues =
            (0..<190).map { "ID-\($0)" } + Array(repeating: "ID-0", count: 10)
        try writeEAResults("ea-results_20260331T230000.json",
                           ea: "SerialNumber", values: tinyAllDistinctValues)
        try writeEAResults("ea-results_20260629T230000.json",
                           ea: "SerialNumber", values: wellSampledIdentifierValues)

        let period = try XCTUnwrap(ReportPeriod.resolve(
            kind: .explicit(start: d("2026-04-01"), end: d("2026-06-30")),
            availableDates: [d("2026-04-01"), d("2026-06-30")], now: d("2026-07-15")))

        let c = PeriodReportService.cardinality(
            profile: profile, ea: "SerialNumber", period: period)
        XCTAssertTrue(PeriodMetricCatalog.looksLikeIdentifier(
            distinct: c.distinct, devices: c.devices),
            "the well-sampled, flagged boundary must win over the tiny, "
            + "higher-ratio-but-unflagged one")
    }

    // MARK: - Batch cardinality

    /// `cardinalityBatch` loads the period's two boundary snapshots once and
    /// shares them across every attribute, where `cardinality(profile:ea:period:)`
    /// reloads per attribute. The decode count is not observable from a
    /// service-level test, so this pins BEHAVIOUR instead: across a 3-EA
    /// fixture (one identifier-shaped only at the start boundary, one only
    /// at the end, one never), the batch verdict for each EA must match what
    /// the per-EA call returns, and the three verdicts must be the expected
    /// mix of flagged/unflagged.
    func testCardinalityBatchMatchesPerEACallsForThreeEAs() throws {
        try writeEAResults("ea-results_20260331T230000.json", attributes: [
            (ea: "SerialNumber", values: (0..<10).map { "SN-\($0)-UNIQUE" }),
            (ea: "AssetTag", values: Array(repeating: "Active", count: 10)),
            (ea: "OSVersion", values: Array(repeating: "15.6", count: 8)
                + ["15.7", "15.7"]),
        ])
        try writeEAResults("ea-results_20260629T230000.json", attributes: [
            (ea: "SerialNumber", values: Array(repeating: "Assigned", count: 10)),
            (ea: "AssetTag", values: (0..<10).map { "AT-\($0)-UNIQUE" }),
            (ea: "OSVersion", values: Array(repeating: "15.7", count: 10)),
        ])

        let period = try XCTUnwrap(ReportPeriod.resolve(
            kind: .explicit(start: d("2026-04-01"), end: d("2026-06-30")),
            availableDates: [d("2026-04-01"), d("2026-06-30")], now: d("2026-07-15")))

        let names = ["SerialNumber", "AssetTag", "OSVersion"]
        let batch = PeriodReportService.cardinalityBatch(
            profile: profile, eas: names, period: period)

        for name in names {
            let perEA = PeriodReportService.cardinality(profile: profile, ea: name, period: period)
            let batched = try XCTUnwrap(batch[name], "batch is missing \(name)")
            XCTAssertEqual(batched.devices, perEA.devices, "\(name) devices mismatch")
            XCTAssertEqual(batched.distinct, perEA.distinct, "\(name) distinct mismatch")
        }

        XCTAssertTrue(PeriodMetricCatalog.looksLikeIdentifier(
            distinct: batch["SerialNumber"]!.distinct, devices: batch["SerialNumber"]!.devices),
            "SerialNumber is identifier-shaped at the start boundary")
        XCTAssertTrue(PeriodMetricCatalog.looksLikeIdentifier(
            distinct: batch["AssetTag"]!.distinct, devices: batch["AssetTag"]!.devices),
            "AssetTag is identifier-shaped at the end boundary")
        XCTAssertFalse(PeriodMetricCatalog.looksLikeIdentifier(
            distinct: batch["OSVersion"]!.distinct, devices: batch["OSVersion"]!.devices),
            "OSVersion is status-shaped at both boundaries")
    }
}
