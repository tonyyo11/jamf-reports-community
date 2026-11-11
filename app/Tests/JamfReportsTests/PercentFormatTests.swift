import XCTest
import ZIPFoundation
@testable import JamfReports

final class PercentFormatTests: XCTestCase {
    private let one = PercentFormat.standard
    private let whole = PercentFormat.whole

    func testBothPrecisionsRoundHalfAwayFromZero() {
        XCTAssertEqual(one.text(56.74), "56.7%")
        XCTAssertEqual(one.text(56.75), "56.8%")
        XCTAssertEqual(whole.text(56.4), "56%")
        XCTAssertEqual(whole.text(56.5), "57%")
        XCTAssertEqual(whole.text(56.7), "57%")
    }

    func testEndsPrintOnlyForExactNoneOrEvery() {
        XCTAssertEqual(whole.text(99.6), "99%")
        XCTAssertEqual(one.text(99.96), "99.9%")
        XCTAssertEqual(whole.text(0.3), "1%")
        XCTAssertEqual(one.text(0.04), "0.1%")
        XCTAssertEqual(whole.text(100), "100%")
        XCTAssertEqual(one.text(100), "100.0%")
        XCTAssertEqual(whole.text(0), "0%")
        XCTAssertEqual(one.text(0), "0.0%")
        XCTAssertEqual(whole.text(104.2), "104%")
        XCTAssertEqual(whole.text(-0.2), "0%", "negative zero prints without a sign")
    }

    func testAbsentAndNotANumber() {
        XCTAssertEqual(whole.text(nil as Double?), "—")
        XCTAssertEqual(whole.text(nil as Double?, missing: "--"), "--")
        XCTAssertEqual(whole.text(.nan), "—")
        XCTAssertEqual(whole.text(3, of: 0), "—")
        XCTAssertEqual(whole.text(1, of: 3), "33%")
    }

    func testPointsHaveTheFiguresPrecision() {
        XCTAssertEqual(one.points(0.4), "0.4 pp")
        XCTAssertEqual(whole.points(0.4), "0 pp")
        XCTAssertEqual(whole.points(1.2), "1 pp")
        XCTAssertEqual(one.changeText(3.24), "3.2%")
    }

    func testAFigureBesideItsThresholdNeverReachesIt() {
        XCTAssertEqual(whole.text(89.6, beside: 90), "89.6%")
        XCTAssertEqual(whole.text(89.4, beside: 90), "89%")
        XCTAssertEqual(one.text(89.96, beside: 90), "89.96%")
        XCTAssertEqual(whole.text(80.3, beside: 80), "80.3%")
        XCTAssertEqual(whole.text(90, beside: 90), "90%")
        XCTAssertEqual(whole.numberText(69.6, beside: 70), "69.6")
    }

    func testConfigReadsOnlyZeroAsWhole() throws {
        func format(_ yaml: String) throws -> PercentFormat {
            try ConfigLoader.loadFromString(yaml).percentFormat
        }
        XCTAssertEqual(try format("thresholds:\n  stale_device_days: 30\n"), .standard)
        XCTAssertEqual(try format("display:\n  percent_decimals: 0\n"), .whole)
        XCTAssertEqual(try format("display:\n  percent_decimals: 1\n"), .standard)
        XCTAssertEqual(try format("display:\n  percent_decimals: 2\n"), .standard)
        XCTAssertEqual(try format("display:\n  percent_decimals: none\n"), .standard)
        XCTAssertEqual(try format("display:\n  percent_decimals: true\n"), .standard)
    }

    func testDoctorNamesAValueThatIsNotZeroOrOne() throws {
        func rows(_ yaml: String) throws -> [DoctorRow] {
            ConfigDoctorService.displayValueRows(try ConfigLoader.rawMapping(fromYAML: yaml))
        }
        XCTAssertTrue(try rows("display:\n  percent_decimals: 0\n").isEmpty)
        XCTAssertTrue(try rows("display:\n  percent_decimals: 1\n").isEmpty)
        XCTAssertTrue(try rows("thresholds: {}\n").isEmpty)
        XCTAssertEqual(try rows("display:\n  percent_decimals: 2\n").map(\.id),
                       ["config.value.display.percent_decimals"])
        XCTAssertEqual(try rows("display:\n  percent_decimals: true\n").count, 1)
        XCTAssertEqual(try rows("display:\n  percent_decimals: \"zero\"\n").count, 1)
    }

    func testTheSchemaKnowsTheKey() throws {
        let raw = try ConfigLoader.rawMapping(fromYAML: "display:\n  percent_decimals: 0\n")
        XCTAssertTrue(ConfigSchema.unknownKeys(in: raw).isEmpty)
        XCTAssertTrue(ConfigEditedKeys.paths.contains(["display", "percent_decimals"]))
    }

    func testTheWriterLeavesAnUnsetFileAloneAtOneDecimal() {
        var root = YAMLCodec.YAMLMapping(entries: [])
        DisplayConfigWriter.apply(percentDecimals: 1, to: &root)
        XCTAssertNil(root.value(for: "display"))
        DisplayConfigWriter.apply(percentDecimals: 0, to: &root)
        XCTAssertEqual(root.value(for: "display")?.mapping?.value(for: "percent_decimals"),
                       .scalar(.int(0)))
        DisplayConfigWriter.apply(percentDecimals: 1, to: &root)
        XCTAssertEqual(root.value(for: "display")?.mapping?.value(for: "percent_decimals"),
                       .scalar(.int(1)))
    }

    // MARK: - Consumers

    func testTrendChangeAtWholeNumbersComparesThePrintedFigures() {
        let up = TrendChange(unit: "%", polarity: .higherIsBetter, first: 56.4, last: 56.6,
                             format: whole)
        XCTAssertEqual(up.pillText, "+1 pp")
        let flat = TrendChange(unit: "%", polarity: .higherIsBetter, first: 56.2, last: 56.4,
                               format: whole)
        XCTAssertEqual(flat.direction, .flat)
        XCTAssertEqual(flat.pillText, "±0")
        XCTAssertEqual(flat.heroText(relativeChange: nil), "No change")
        let tenth = TrendChange(unit: "%", polarity: .higherIsBetter, first: 56.2, last: 56.4,
                                format: one)
        XCTAssertEqual(tenth.pillText, "+0.2 pp")
    }

    func testWorkbookNumberFormatFollowsThePrecision() throws {
        func styles(_ format: PercentFormat) throws -> String {
            let wb = Workbook(percentFormat: format)
            wb.addSheet("S").write(0.567, row: 0, col: 0, format: .pct)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("pct-\(UUID().uuidString).xlsx")
            defer { try? FileManager.default.removeItem(at: url) }
            try wb.write(to: url)
            let archive = try Archive(url: url, accessMode: .read)
            let entry = try XCTUnwrap(archive["xl/styles.xml"])
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            return String(decoding: data, as: UTF8.self)
        }
        XCTAssertTrue(try styles(whole).contains(#"formatCode="0%""#))
        XCTAssertTrue(try styles(one).contains(#"formatCode="0.0%""#))
    }

    func testCSVFolderPrintsPercentCellsAtThePrecision() {
        let wb = Workbook(percentFormat: whole)
        let sheet = wb.addSheet("S")
        sheet.write(0.567, row: 0, col: 0, format: .pct)
        XCTAssertEqual(sheet.csvText(percentFormat: whole), "57%\n")
        XCTAssertEqual(sheet.csvText(percentFormat: one), "56.7%\n")
    }

    func testAlertTextKeepsTheFigureApartFromItsThreshold() {
        let rule = AlertRule(metric: "filevault_pct", when: "below", threshold: 90)
        let summary = DailySummary(
            date: "2026-11-11", totalDevices: 10, fileVaultPct: 89.6, compliancePct: nil,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil)
        let hit = MetricAlertEvaluator.evaluate(
            rules: [rule], current: summary, prior: nil, format: whole).first
        XCTAssertEqual(hit?.message, "89.6% — below threshold 90")
        let low = DailySummary(
            date: "2026-11-11", totalDevices: 10, fileVaultPct: 85.2, compliancePct: nil,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil)
        XCTAssertEqual(MetricAlertEvaluator.evaluate(
            rules: [rule], current: low, prior: nil, format: whole).first?.message,
            "85% — below threshold 90")
    }

    func testFleetIssueLinesUseTheFormatBesideTheirThreshold() {
        let summary = DailySummary(
            date: "2026-11-11", totalDevices: 10, fileVaultPct: 89.6, compliancePct: nil,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: 70.2)
        let reasons = fleetProfileIssues(summary, format: whole).map(\.reason)
        XCTAssertTrue(reasons.contains("FileVault 89.6% (below 90%)"), "\(reasons)")
        XCTAssertTrue(reasons.contains("Patch 70% (below 80%)"), "\(reasons)")
    }

    func testHTMLSecurityTilesFollowTheWorkspacePrecision() throws {
        let config = try ConfigLoader.loadFromString("display:\n  percent_decimals: 0\n")
        let report = HtmlReport(config: config, dataDir: URL(fileURLWithPath: "/tmp/nonexistent"))
        let html = report.buildSummaryTiles(
            total: 10, fileVaultPct: 56.7, sipPct: 99.6, firewallPct: nil, gatekeeperPct: 100,
            fleet: nil)
        XCTAssertTrue(html.contains(">57%<"), html)
        XCTAssertTrue(html.contains(">99%<"), html)
        XCTAssertTrue(html.contains(">100%<"), html)
        XCTAssertFalse(html.contains("56.7%"), html)
    }

    // MARK: - The class stays closed

    /// A percentage printed outside `PercentFormat` would ignore `display.percent_decimals`.
    /// Axis ticks, SVG coordinates and data labels from jamf-cli are not shares on screen.
    func testNoPercentageIsPrintedOutsideTheFormatter() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/JamfReports", isDirectory: true)
        let pattern = try NSRegularExpression(pattern:
            #"%\.[0-9]f%%|%\.[0-9]f pp|"%\.[0-9]f", [^)]*\)\)(%|pp)|\.rounded\(\)\)\)%|Int\([^()]*\)\)%|"[0-9]+\.[0-9]+%""#)
        let allowed: [String: Int] = [
            "Models/PercentFormat.swift": 0,
            // The patch record's fallback label when jamf-cli sends none; no screen shows it.
            "Services/DeviceInventoryService.swift": 1,
            // Chart y-axis ticks (0, 25, 50, 75, 100).
            "Views/TrendsView.swift": 1,
            "Views/FleetOverviewView.swift": 1,
            // The workbook's `0.0%` number format code.
            "Engine/OOXMLWriter.swift": 1,
        ]
        let walker = try XCTUnwrap(FileManager.default.enumerator(atPath: sources.path))
        var counts: [String: Int] = [:]
        // Demo data is fixed labels standing in for tenant data; it never reads a workspace.
        for case let relative as String in walker
        where relative.hasSuffix(".swift") && !relative.hasPrefix("Models/DemoData") {
            // Doc comments quote figures ("93.3%") and are not output.
            let text = try String(contentsOf: sources.appendingPathComponent(relative),
                                  encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.drop { $0 == " " }.hasPrefix("//") }
                .joined(separator: "\n")
            let hits = pattern.numberOfMatches(
                in: text, range: NSRange(location: 0, length: text.utf16.count))
            if hits > 0, relative != "Models/PercentFormat.swift" { counts[relative] = hits }
        }
        XCTAssertEqual(counts, allowed.filter { $0.value > 0 },
                       "print the percentage through PercentFormat")
    }
}
