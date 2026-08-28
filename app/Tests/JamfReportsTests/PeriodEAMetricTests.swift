import XCTest
@testable import JamfReports

final class PeriodEAMetricTests: XCTestCase {
    private let cal = Calendar(identifier: .gregorian)
    private func d(_ s: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.calendar = cal; f.timeZone = .current
        return f.date(from: s)!
    }
    private func snap(_ date: String, _ values: [String: String]) -> PeriodEASnapshot {
        PeriodEASnapshot(date: d(date), valuesByEA: ["Widget Status": values])
    }
    private func period() -> ReportPeriod {
        ReportPeriod.resolve(kind: .explicit(start: d("2026-04-01"), end: d("2026-06-30")),
            availableDates: [d("2026-04-01"), d("2026-06-30")],
            now: d("2026-07-15"), calendar: cal)!
    }
    private func metric(match: String?) -> PeriodMetric {
        PeriodMetric(id: "ea:Widget Status", label: "Widget Status",
                     unit: match == nil ? .distribution : .count,
                     source: .extensionAttribute(name: "Widget Status", match: match))
    }

    // MARK: - Configured EA: a single figure

    func testConfiguredEAYieldsMatchCountAndChange() {
        let row = PeriodReportModel.eaRow(
            metric: metric(match: "On"), name: "Widget Status", match: "On", period: period(),
            snapshots: [snap("2026-04-01", ["a": "On", "b": "Off"]),
                        snap("2026-06-30", ["a": "On", "b": "On", "c": "On"])])
        XCTAssertEqual(row.startValue, 1)
        XCTAssertEqual(row.endValue, 3)
        XCTAssertEqual(row.change, 2)
    }

    /// Matching is case-insensitive substring, as `connected_value` is elsewhere.
    func testMatchIsCaseInsensitiveSubstring() {
        let row = PeriodReportModel.eaRow(
            metric: metric(match: "on"), name: "Widget Status", match: "on", period: period(),
            snapshots: [snap("2026-04-01", ["a": "Installed and ON"])])
        XCTAssertEqual(row.startValue, 1)
    }

    // MARK: - Unconfigured EA: a distribution

    func testUnconfiguredEAYieldsDistributionsAndNoScalar() {
        let row = PeriodReportModel.eaRow(
            metric: metric(match: nil), name: "Widget Status", match: nil, period: period(),
            snapshots: [snap("2026-04-01", ["a": "On", "b": "Off", "c": "Off"]),
                        snap("2026-06-30", ["a": "On", "b": "On", "c": "Off"])])
        XCTAssertNil(row.startValue)
        XCTAssertNil(row.change)
        XCTAssertEqual(row.startDistribution["Off"], 2)
        XCTAssertEqual(row.endDistribution["On"], 2)
    }

    /// An EA absent at a boundary reports no value — not zero devices.
    func testEAAbsentAtBoundaryReportsNoValue() {
        let row = PeriodReportModel.eaRow(
            metric: metric(match: "On"), name: "Widget Status", match: "On", period: period(),
            snapshots: [PeriodEASnapshot(date: d("2026-06-30"), valuesByEA: [:])])
        XCTAssertNil(row.startValue)
        XCTAssertNil(row.endValue)
    }

    // MARK: - The cap, and the identifier heuristic

    /// An identifier-shaped EA would otherwise put one row per device into a
    /// workbook bound for a management document.
    func testDistributionIsCappedAndReportsWhatItDropped() {
        var many: [String: String] = [:]
        for i in 0..<200 { many["device\(i)"] = "unique-value-\(i)" }
        let row = PeriodReportModel.eaRow(
            metric: metric(match: nil), name: "Widget Status", match: nil, period: period(),
            snapshots: [snap("2026-04-01", many)])
        XCTAssertEqual(row.startDistribution.count, PeriodReportModel.maxDistinctValues)
        XCTAssertGreaterThan(row.omittedValueCount, 0, "truncation must be stated, not silent")
    }

    /// The cap keeps the most common values, which is what a status EA needs.
    func testCapKeepsTheMostCommonValues() {
        var values: [String: String] = ["a": "Common", "b": "Common", "c": "Common"]
        for i in 0..<40 { values["x\(i)"] = "rare-\(i)" }
        let row = PeriodReportModel.eaRow(
            metric: metric(match: nil), name: "Widget Status", match: nil, period: period(),
            snapshots: [snap("2026-04-01", values)])
        XCTAssertEqual(row.startDistribution["Common"], 3)
    }

    /// One distinct value per device is a serial or hostname, not a status.
    func testIdentifierShapedEAIsFlagged() {
        XCTAssertTrue(PeriodMetricCatalog.looksLikeIdentifier(distinct: 98, devices: 100))
        XCTAssertTrue(PeriodMetricCatalog.looksLikeIdentifier(distinct: 100, devices: 100))
    }

    func testStatusShapedEAIsNotFlagged() {
        XCTAssertFalse(PeriodMetricCatalog.looksLikeIdentifier(distinct: 3, devices: 100))
        XCTAssertFalse(PeriodMetricCatalog.looksLikeIdentifier(distinct: 12, devices: 500))
    }

    /// A tiny fleet is all-distinct by coincidence; flagging it would cry wolf.
    func testTinySampleIsNotFlagged() {
        XCTAssertFalse(PeriodMetricCatalog.looksLikeIdentifier(distinct: 3, devices: 3))
        XCTAssertFalse(PeriodMetricCatalog.looksLikeIdentifier(distinct: 0, devices: 0))
    }

    // MARK: - Reader

    func testReaderGroupsRowsByEANameAndDevice() throws {
        let data = Data("""
        [{"computer_id":"1","ea_name":"Widget Status","value":"On"},
         {"computer_id":"2","ea_name":"Widget Status","value":"Off"}]
        """.utf8)
        let s = try XCTUnwrap(PeriodEAReader.snapshot(from: data, at: d("2026-04-01")))
        XCTAssertEqual(s.valuesByEA["Widget Status"]?.count, 2)
    }

    func testReaderReturnsNilForUnparseableData() {
        XCTAssertNil(PeriodEAReader.snapshot(from: Data("not json".utf8), at: d("2026-04-01")))
    }

    func testCardinalityReportsDistinctAndDeviceCounts() {
        let s = snap("2026-04-01", ["a": "On", "b": "On", "c": "Off"])
        let c = s.cardinality(of: "Widget Status")
        XCTAssertEqual(c.devices, 3)
        XCTAssertEqual(c.distinct, 2)
    }
}
