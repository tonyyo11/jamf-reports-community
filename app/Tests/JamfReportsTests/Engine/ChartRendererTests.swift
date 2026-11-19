import XCTest
import CoreGraphics
import ImageIO
@testable import JamfReports

/// Pixel and layout checks for `ChartRenderer`. A chart that only "returns PNG data" can
/// still draw nothing, or draw text on text, so these decode the image or read the layout.
final class ChartRendererTests: XCTestCase {

    // MARK: - Helpers

    /// RGBA pixels of a PNG, top row first, with its pixel size.
    private func pixels(_ png: Data) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try XCTUnwrap(CGContext(
            data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (bytes, w, h)
    }

    /// Pixels inside `rect` (chart points, top-left origin; the PNG is drawn at 2×) whose
    /// colour is clearly not white, grey or black: drawn series, not grid or text.
    private func colouredPixels(_ png: Data, in rect: CGRect) throws -> Int {
        let (bytes, w, h) = try pixels(png)
        let x0 = max(0, Int(rect.minX * 2)), x1 = min(w, Int(rect.maxX * 2))
        let y0 = max(0, Int(rect.minY * 2)), y1 = min(h, Int(rect.maxY * 2))
        var count = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = (y * w + x) * 4
                let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2])
                if max(r, g, b) - min(r, g, b) > 40 { count += 1 }
            }
        }
        return count
    }

    private func day(_ text: String) -> Date {
        SummaryJSONParser.dateFormatter.date(from: text) ?? .distantPast
    }

    private let medium = ChartPalette.complianceBandColors[3]

    // MARK: - One day of history

    func testOneDayBandTrendDrawsTheBand() throws {
        let series = [ChartSeries(label: "Medium (31–50)", color: medium,
                                  points: [(date: day("2026-11-16"), value: 3)])]
        let png = try XCTUnwrap(ChartRenderer.stackedAreaChart(series: series, title: "One day"))
        // The middle of the canvas is inside the plot whatever the legend and title take.
        let middle = CGRect(x: 300, y: 200, width: 600, height: 250)
        XCTAssertGreaterThan(try colouredPixels(png, in: middle), 500,
                             "a single day of band counts must be drawn, not left as empty axes")
    }

    func testOneDayLineDrawsItsPointInTheMiddle() throws {
        let series = [ChartSeries(label: "Total Computers", color: medium,
                                  points: [(date: day("2026-11-16"), value: 4)])]
        let png = try XCTUnwrap(ChartRenderer.lineChart(series: series, yAxis: .count))
        XCTAssertGreaterThan(try colouredPixels(png, in: CGRect(x: 560, y: 60, width: 80, height: 460)), 20)
    }

    // MARK: - Layout

    private let bandLegend = ["Pass (0)", "Low (1–10)", "Med-Low (11–30)", "Medium (31–50)",
                              "High (>50)"]

    private func assertNoOverlap(_ lay: ChartRenderer.Layout, size: CGSize,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let canvas = CGRect(origin: .zero, size: size)
        let rects = lay.allRects
        for (i, a) in rects.enumerated() {
            XCTAssertTrue(canvas.contains(a), "\(a) leaves the canvas", file: file, line: line)
            for b in rects[(i + 1)...] where !(a.isEmpty || b.isEmpty) {
                XCTAssertFalse(a.intersects(b), "\(a) overlaps \(b)", file: file, line: line)
            }
        }
    }

    func testTitleLegendAxisTitlePlotAndFootnoteNeverOverlap() {
        let size = ChartRenderer.defaultSize
        let lay = ChartRenderer.layout(
            size: size, title: "mSCP/STIG Compliance Trend — CIS Level 1 Audit Only",
            legend: bandLegend, yLabel: "Macs", yTickLabels: ["0", "1", "2", "3", "4"],
            xLabelRowCount: 1, footnote: "Not shown: 1 Mac with no compliance data on the last day.")
        assertNoOverlap(lay, size: size)
        XCTAssertEqual(lay.legend.count, bandLegend.count)
    }

    func testALegendTooWideForOneRowWrapsDownwardAboveThePlot() {
        let size = CGSize(width: 600, height: 400)
        let labels = (1...9).map { "A fairly long series label \($0)" }
        let lay = ChartRenderer.layout(size: size, title: "A title", legend: labels, yLabel: nil,
                                       yTickLabels: ["0", "100"], xLabelRowCount: 2, footnote: nil)
        assertNoOverlap(lay, size: size)
        let rows = Set(lay.legend.map(\.minY))
        XCTAssertGreaterThan(rows.count, 1)
        XCTAssertTrue(lay.legend.allSatisfy { $0.maxY < lay.plot.minY })
        XCTAssertTrue(lay.legend.allSatisfy { $0.minY > (lay.title?.maxY ?? 0) })
    }

    // MARK: - Y axis

    func testCountAxesUseWholeRoundStepsWithRoomAbove() {
        XCTAssertEqual(ChartRenderer.axisScale(maxValue: 4, kind: .count), .init(top: 5, step: 1))
        XCTAssertEqual(ChartRenderer.axisScale(maxValue: 1, kind: .count), .init(top: 2, step: 1))
        XCTAssertEqual(ChartRenderer.axisScale(maxValue: 0, kind: .count), .init(top: 1, step: 1))
        XCTAssertEqual(ChartRenderer.axisScale(maxValue: 6000, kind: .count),
                       .init(top: 8000, step: 2000))
        XCTAssertEqual(ChartRenderer.axisScale(maxValue: 4, kind: .count).ticks, [0, 1, 2, 3, 4, 5])
    }

    func testPercentAxesRunToOneHundredAndGrowOnlyPastIt() {
        XCTAssertEqual(ChartRenderer.axisScale(maxValue: 90, kind: .percent), .init(top: 100, step: 20))
        XCTAssertEqual(ChartRenderer.axisScale(maxValue: 0, kind: .percent), .init(top: 100, step: 20))
        XCTAssertGreaterThanOrEqual(ChartRenderer.axisScale(maxValue: 130, kind: .percent).top, 130)
    }

    func testAnAxisNeverClipsItsLargestValue() {
        for value in [0.3, 1, 2.5, 3, 7, 9.9, 12, 99, 101, 777, 1234, 59_999] {
            for kind in [ChartYAxis.count, .percent] {
                let scale = ChartRenderer.axisScale(maxValue: value, kind: kind)
                XCTAssertGreaterThanOrEqual(scale.top, value, "\(value) \(kind)")
                XCTAssertLessThanOrEqual(scale.ticks.count, 8, "\(value) \(kind)")
            }
        }
    }

    func testTickLabelsAreWholeNumbersOrPercentages() {
        XCTAssertEqual(ChartRenderer.tickLabel(2, kind: .count), "2")
        XCTAssertEqual(ChartRenderer.tickLabel(8000, kind: .count), "8,000")
        XCTAssertEqual(ChartRenderer.tickLabel(60, kind: .percent), "60%")
    }

    // MARK: - Dates

    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: zone) ?? .current
        return c
    }

    private func parse(_ text: String, in cal: Calendar) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: text) ?? .distantPast
    }

    func testDateTicksNeverRepeatADayAndLandOnTheSummariesOwnDays() {
        for zone in ["America/Los_Angeles", "Asia/Tokyo", "UTC"] {
            let cal = calendar(zone)
            // The band trend's six days, which put "Nov 13" on two ticks before.
            let ticks = ChartRenderer.dateTicks(from: parse("2026-11-11", in: cal),
                                                to: parse("2026-11-16", in: cal), calendar: cal)
            let labels = ticks.map { ChartRenderer.dayLabel($0, calendar: cal, withYear: false) }
            XCTAssertEqual(labels, ["Nov 11", "Nov 12", "Nov 13", "Nov 14", "Nov 15", "Nov 16"], zone)
        }
    }

    func testLongSpansStepByWholeDays() {
        let cal = calendar("UTC")
        let ticks = ChartRenderer.dateTicks(from: parse("2026-10-01", in: cal),
                                            to: parse("2026-10-31", in: cal), calendar: cal)
        XCTAssertEqual(ticks.count, 7)
        XCTAssertEqual(Set(ticks).count, ticks.count)
        XCTAssertEqual(ChartRenderer.dateTicks(from: parse("2026-10-01", in: cal),
                                               to: parse("2026-10-01", in: cal), calendar: cal).count, 1)
    }

    func testTheNewestDayIsAlwaysLabelled() {
        let cal = calendar("UTC")
        // Ten days with room for five labels: the step is 3, counted back from Nov 19.
        let ticks = ChartRenderer.dateTicks(from: parse("2026-11-10", in: cal),
                                            to: parse("2026-11-19", in: cal), calendar: cal, maxTicks: 5)
        XCTAssertEqual(ticks.map { ChartRenderer.dayLabel($0, calendar: cal, withYear: false) },
                       ["Nov 10", "Nov 13", "Nov 16", "Nov 19"])
        // A full-width workbook chart has room for every one of ten days.
        let plotWidth = ChartRenderer.layout(size: ChartRenderer.defaultSize, title: nil, legend: [],
                                             yLabel: nil, yTickLabels: ["0"], xLabelRowCount: 1,
                                             footnote: nil).plot.width
        XCTAssertGreaterThanOrEqual(ChartRenderer.maxDateTicks(forWidth: plotWidth), 10)
    }

    // MARK: - OS adoption

    private func sofaRow(_ family: String, _ version: String) -> SOFAFeedService.OSFamilyRow {
        SOFAFeedService.OSFamilyRow(platform: "macOS", osFamily: family, productVersion: version,
                                    build: "", releaseDate: "", daysSinceRelease: nil,
                                    activelyExploitedCVEs: 0, securityInfoURL: "")
    }

    private let nfrRows = [
        InventorySummaryRow(osVersion: "Unknown", count: 1),
        InventorySummaryRow(osVersion: "26.6.2", count: 2),
        InventorySummaryRow(osVersion: "15.7.7", count: 1),
    ]

    func testOSBarsAreNamedFromSOFAWithUnreportedVersionsLast() {
        let bars = OSAdoptionChart.bars(rows: nfrRows, sofaRows: [
            sofaRow("Golden Gate 27", "27.2.1"), sofaRow("Tahoe 26", "26.7.3"),
            sofaRow("Sequoia 15", "15.8.3")])
        XCTAssertEqual(bars.map(\.label), ["macOS Tahoe 26", "macOS Sequoia 15", "Version not reported"])
        XCTAssertEqual(bars.map(\.macs), [2, 1, 1])
        XCTAssertEqual(bars.map(\.onLatest), [0, 0, nil])
        let data = OSAdoptionChart.chartData(bars)
        XCTAssertEqual(data.valueLabels, ["2 Macs · 50%", "1 Mac · 25%", "1 Mac · 25%"])
        XCTAssertEqual(data.subLabels?.first, "0 of 2 on 26.7.3")
        XCTAssertEqual(data.categories.last, "Version not reported")
    }

    func testOSBarsWithoutAFeedNeverCallAMacBehind() {
        let bars = OSAdoptionChart.bars(rows: nfrRows, sofaRows: [])
        XCTAssertEqual(bars.map(\.label), ["macOS 26", "macOS 15", "Version not reported"])
        XCTAssertTrue(bars.allSatisfy { $0.onLatest == nil })
        XCTAssertEqual(OSAdoptionChart.chartData(bars).subLabels?.first,
                       "Latest release not in the SOFA feed")
    }

    func testAMajorTheFeedDoesNotTrackIsNotKnownRatherThanBehind() {
        let bars = OSAdoptionChart.bars(rows: [InventorySummaryRow(osVersion: "14.8.2", count: 3)],
                                        sofaRows: [sofaRow("Tahoe 26", "26.7.3")])
        XCTAssertEqual(bars.first?.onLatest, nil)
    }

    func testMajorsSortNumericallyNotAsText() {
        let rows = [InventorySummaryRow(osVersion: "9.0", count: 1),
                    InventorySummaryRow(osVersion: "10.15.7", count: 1),
                    InventorySummaryRow(osVersion: "26.1", count: 1)]
        XCTAssertEqual(OSAdoptionChart.bars(rows: rows, sofaRows: []).compactMap(\.major), [26, 10, 9])
    }

    func testOnLatestCountsAgreeWithTheOSCurrentFigure() {
        let rows = [InventorySummaryRow(osVersion: "26.7.3", count: 3),
                    InventorySummaryRow(osVersion: "26.6.2", count: 1),
                    InventorySummaryRow(osVersion: "15.8.3", count: 2),
                    InventorySummaryRow(osVersion: "Unknown", count: 2)]
        let sofa = [sofaRow("Tahoe 26", "26.7.3"), sofaRow("Sequoia 15", "15.8.3")]
        let onLatest = OSAdoptionChart.bars(rows: rows, sofaRows: sofa).compactMap(\.onLatest).reduce(0, +)
        let counts = Dictionary(rows.map { ($0.osVersion, $0.count) }, uniquingKeysWith: +)
        let pct = try? XCTUnwrap(ReportEngine.osCurrentPercent(macOSRows: sofa, osCounts: counts,
                                                              totalDevices: 8))
        // The OS-current figure is over Macs with a reported version (6 here).
        XCTAssertEqual(Double(onLatest) / 6 * 100, pct ?? -1, accuracy: 0.01)
    }

    // MARK: - Previews

    /// Writes every chart shape Tony saw to `JRC_CHART_PREVIEW_DIR` for a person to look at.
    /// Skipped unless that variable names a folder.
    func testWritePreviewsWhenAsked() throws {
        guard let dir = ProcessInfo.processInfo.environment["JRC_CHART_PREVIEW_DIR"], !dir.isEmpty
        else { throw XCTSkip("set JRC_CHART_PREVIEW_DIR to write chart previews") }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func write(_ name: String, _ png: Data?) throws {
            try XCTUnwrap(png, name).write(to: out.appendingPathComponent("\(name).png"))
        }
        let days = (10...16).map { day("2026-11-\($0)") }
        try write("fleet-trend", ChartRenderer.lineChart(
            series: [ChartSeries(label: "Total Computers", color: ChartPalette.cgColor(forMetric: .managedDevices),
                                 points: zip(days, [2, 4, 4, 4, 4, 4, 4]).map { ($0, Double($1)) })],
            yAxis: .count, title: "Fleet Size Trend", yLabel: "Macs"))
        try write("stale-trend", ChartRenderer.lineChart(
            series: [ChartSeries(label: "Stale Devices", color: ChartPalette.cgColor(forMetric: .stale),
                                 points: zip(days, [0, 1, 1, 1, 1, 1, 1]).map { ($0, Double($1)) })],
            yAxis: .count, title: "Stale Device Count Trend", yLabel: "Macs"))
        try write("security-trend", ChartRenderer.lineChart(series: [
            ChartSeries(label: "FileVault %", color: ChartPalette.cgColor(forMetric: .fileVault),
                        points: [(days[0], 0), (days[1], 0)]),
            ChartSeries(label: "Patch %", color: ChartPalette.cgColor(forMetric: .patch),
                        points: zip(days.dropFirst(), [90, 77, 77, 70, 73, 73]).map { ($0, Double($1)) })],
            yAxis: .percent, title: "Security Metric Trends", yLabel: "Percent of Macs"))
        let bandColors = ChartPalette.complianceBandColors
        let bandValues: [[Double]] = [[0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0],
                                      [3, 3, 3, 3, 3, 3], [0, 0, 0, 0, 0, 0]]
        try write("mscp-band-trend", ChartRenderer.stackedAreaChart(
            series: zip(zip(bandLegend, bandColors), bandValues).map { lc, values in
                ChartSeries(label: lc.0, color: lc.1, points: zip(days.dropFirst(), values).map { ($0, $1) })
            },
            title: "mSCP/STIG Compliance Trend — CIS Level 1 Audit Only", yLabel: "Macs",
            footnote: "Not shown: 1 Mac with no compliance data on the last day."))
        try write("mscp-band-trend-one-day", ChartRenderer.stackedAreaChart(
            series: zip(bandLegend, bandColors).map { ChartSeries(label: $0, color: $1,
                points: [(days[6], $0.hasPrefix("Medium") ? 3 : 0)]) },
            title: "mSCP/STIG Compliance Trend — CIS Level 1 Audit Only", yLabel: "Macs"))
        let bars = OSAdoptionChart.bars(rows: nfrRows, sofaRows: [
            sofaRow("Golden Gate 27", "27.2.1"), sofaRow("Tahoe 26", "26.7.3"), sofaRow("Sequoia 15", "15.8.3")])
        try write("os-adoption", ChartRenderer.barChart(
            data: OSAdoptionChart.chartData(bars), yAxis: .percent,
            title: "macOS Adoption by Major Version", yLabel: "Percent of Macs",
            footnote: OSAdoptionChart.footnote(bars, hasFeed: true)))
        let slices = [("No Data", 1, ChartPalette.noDataColor), ("Pass (0)", 0, bandColors[0]),
                      ("Low (1–10)", 0, bandColors[1]), ("Med-Low (11–30)", 0, bandColors[2]),
                      ("Medium (31–50)", 3, bandColors[3]), ("High (>50)", 0, bandColors[4])]
            .map { ChartRenderer.DonutSlice(label: $0.0, count: $0.1, pct: Double($0.1) / 4 * 100, color: $0.2) }
        try write("mscp-donut", ChartRenderer.donutChart(
            slices: slices, title: "CIS Level 1 Audit Only — compliance bands, all Macs",
            footer: "Total systems: 4 · Baseline: 112 auditable rules"))
    }
}
