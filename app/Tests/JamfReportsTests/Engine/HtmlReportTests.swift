import Foundation
import XCTest
@testable import JamfReports

// MARK: - HtmlReportTests

final class HtmlReportTests: XCTestCase {

    // MARK: - Helpers

    private func makeReport(dataDir: URL = URL(fileURLWithPath: "/tmp/nonexistent-data")) -> HtmlReport {
        HtmlReport(config: ReportConfig().withDefaults(), dataDir: dataDir)
    }

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("HtmlReportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    // MARK: - Section: loadJSONList

    func testLoadJSONListReturnsEmptyWhenNoCachedData() {
        let report = makeReport()
        let result = report.loadJSONList(kinds: ["nonexistent-kind"])
        XCTAssertTrue(result.isEmpty)
    }

    func testLoadJSONListFallsThroughMultipleKinds() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Write a valid JSON file under the second kind name
        let kindDir = dir.appendingPathComponent("packages", isDirectory: true)
        try FileManager.default.createDirectory(at: kindDir, withIntermediateDirectories: true)
        let json: [[String: Any]] = [["name": "Firefox.pkg", "category": "Browsers"]]
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: kindDir.appendingPathComponent("packages_2026.json"))

        let report = makeReport(dataDir: dir)
        let result = report.loadJSONList(kinds: ["nonexistent", "packages"])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?["name"] as? String, "Firefox.pkg")
    }

    // MARK: - History: resolvedHistoryPath

    func testResolvedHistoryPathDefaultsNextToOutput() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let outputURL = tmp.appendingPathComponent("report.html")
        let report = makeReport()
        let path = report.resolvedHistoryPath("", outputURL: outputURL)
        XCTAssertEqual(path.lastPathComponent, "html_history.json")
        XCTAssertEqual(path.deletingLastPathComponent().path, tmp.path)
    }

    /// Relative to the config file's folder, as config.example.yaml says.
    func testResolvedHistoryPathRelative() throws {
        let (dataDir, outputURL) = try historyWorkspace(config: "columns: {}\n")
        let report = makeReport(dataDir: dataDir)
        let path = report.resolvedHistoryPath("snapshots/history.json", outputURL: outputURL)
        XCTAssertEqual(
            path.path,
            dataDir.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent("snapshots/history.json").path)
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    /// A workspace holding `config` and its data folder; the report goes in Generated Reports.
    private func historyWorkspace(config: String) throws -> (dataDir: URL, output: URL) {
        let workspace = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: workspace) }
        try config.write(to: workspace.appendingPathComponent("config.yaml"), atomically: true,
                         encoding: .utf8)
        return (workspace.appendingPathComponent("jamf-cli-data", isDirectory: true),
                workspace.appendingPathComponent("Generated Reports/report.html"))
    }

    /// The history file is written to, so `html.history_file` follows the rules every path
    /// config.yaml names follows. A refused path is said once and the default is used.
    func testARefusedHistoryFileFallsBackBesideTheReportWithOneWarning() throws {
        let (dataDir, outputURL) = try historyWorkspace(config: "columns: {}\n")
        let fallback = outputURL.deletingLastPathComponent()
            .appendingPathComponent("html_history.json")
        for typed in ["../history.json", "/Users/Shared/history.json", "~/history.json",
                      "~/.ssh/config", "/var/log/history.json"] {
            let lines = Lines()
            var report = makeReport(dataDir: dataDir)
            report.onLine = { lines.add($0.text) }
            XCTAssertEqual(report.resolvedHistoryPath(typed, outputURL: outputURL).path,
                           fallback.path, typed)
            XCTAssertEqual(lines.all.count, 1, typed)
            XCTAssertTrue(lines.all.first?.hasPrefix("[warn] html.history_file") == true,
                          "\(lines.all)")
        }
    }

    /// With history off the report neither resolves nor writes `html.history_file`, so a
    /// refused path is not warned about for nothing; turned on, it is warned about once.
    func testAHistoryFileIsResolvedOnlyWhenHistoryIsTracked() throws {
        for (tracked, warnings) in [(false, 0), (true, 1)] {
            let (dataDir, outputURL) = try historyWorkspace(config: """
            html:
              track_history: \(tracked)
              history_file: /var/log/history.json
            """)
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let lines = Lines()
            var report = makeReport(dataDir: dataDir)
            report.onLine = { lines.add($0.text) }

            let section = report.buildHistorySection(security: [], outputURL: outputURL)

            XCTAssertEqual(section.isEmpty, !tracked)
            XCTAssertEqual(lines.all.count, warnings, "\(lines.all)")
            XCTAssertEqual(FileManager.default.fileExists(atPath: outputURL
                .deletingLastPathComponent().appendingPathComponent("html_history.json").path),
                tracked)
        }
    }

    func testTheSensitiveFoldersStayRefusedWithTheOptIn() throws {
        let (dataDir, outputURL) = try historyWorkspace(
            config: "output:\n  allow_absolute_paths: true\n")
        let report = makeReport(dataDir: dataDir)
        let away = "~/.jrc-history-\(UUID().uuidString)/history.json"
        XCTAssertEqual(report.resolvedHistoryPath(away, outputURL: outputURL).path,
                       NSString(string: away).expandingTildeInPath)
        XCTAssertEqual(
            report.resolvedHistoryPath("~/.ssh/config", outputURL: outputURL).lastPathComponent,
            "html_history.json")
    }

    // MARK: - History: append + round-trip

    func testHistoryAppendRoundTrips() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let histPath = tmp.appendingPathComponent("history.json")

        // Write an initial history file with one entry.
        let initial: [[String: Any]] = [
            ["ts": "2026-01-01T00:00:00Z", "versions": [["v": "15.4", "c": 40]]],
        ]
        let initialData = try JSONSerialization.data(withJSONObject: initial)
        try initialData.write(to: histPath)

        // Verify the written file round-trips correctly.
        let loaded = try JSONSerialization.jsonObject(with: Data(contentsOf: histPath))
        let arr = loaded as? [[String: Any]]
        XCTAssertEqual(arr?.count, 1)
        XCTAssertEqual(arr?.first?["ts"] as? String, "2026-01-01T00:00:00Z")
    }

    // MARK: - History: renderHistorySVG

    func testRenderHistorySVGTooFewPoints() {
        let report = makeReport()
        let single = [HtmlReport.HistoryEntry(
            timestamp: "2026-01-01T00:00:00Z",
            versions: [("15.4", 50)]
        )]
        let html = report.renderHistorySVG(history: single)
        XCTAssertTrue(html.contains("Not enough data"))
    }

    func testRenderHistorySVGProducesPolyline() {
        let report = makeReport()
        let entries = [
            HtmlReport.HistoryEntry(timestamp: "2026-01-01T00:00:00Z", versions: [("15.4", 50)]),
            HtmlReport.HistoryEntry(timestamp: "2026-02-01T00:00:00Z", versions: [("15.4", 55)]),
            HtmlReport.HistoryEntry(timestamp: "2026-03-01T00:00:00Z", versions: [("15.4", 60)]),
        ]
        let svg = report.renderHistorySVG(history: entries)
        XCTAssertTrue(svg.contains("<svg"), "Should produce an SVG element")
        XCTAssertTrue(svg.contains("<polyline"), "Should contain a polyline element")
        XCTAssertTrue(svg.contains("<circle"), "Should contain data point circles")
    }

    func testRenderHistorySVGEscapesLabels() {
        let report = makeReport()
        let entries = [
            HtmlReport.HistoryEntry(
                timestamp: "2026-01-01T00:00:00Z<script>",
                versions: [("15.4", 50)]
            ),
            HtmlReport.HistoryEntry(
                timestamp: "2026-02-01T00:00:00Z",
                versions: [("15.4", 55)]
            ),
        ]
        let svg = report.renderHistorySVG(history: entries)
        XCTAssertFalse(svg.contains("<script>"), "XSS in labels must be escaped")
    }

    func testRenderHistorySVGNodeCount() {
        let report = makeReport()
        let entries = (1...5).map { month in
            HtmlReport.HistoryEntry(
                timestamp: "2026-0\(month)-01T00:00:00Z",
                versions: [("15.4", 50 + month)]
            )
        }
        let svg = report.renderHistorySVG(history: entries)
        // Should have 5 circle elements (one per data point)
        let circleCount = svg.components(separatedBy: "<circle").count - 1
        XCTAssertEqual(circleCount, 5)
    }

    // MARK: - Helper: HtmlSectionFormatters.escapeHTML

    func testHtmlEscapeAmpersand() {
        XCTAssertEqual(HtmlSectionFormatters.escapeHTML("A&B"), "A&amp;B")
    }

    func testHtmlEscapeTags() {
        XCTAssertEqual(HtmlSectionFormatters.escapeHTML("<b>bold</b>"), "&lt;b&gt;bold&lt;/b&gt;")
    }

    // MARK: - Helper: asInt

    func testAsIntFromInt() {
        let report = makeReport()
        XCTAssertEqual(report.asInt(42), 42)
    }

    func testAsIntFromString() {
        let report = makeReport()
        XCTAssertEqual(report.asInt("99"), 99)
    }

    func testAsIntFromNilReturnsNil() {
        let report = makeReport()
        XCTAssertNil(report.asInt(nil))
    }

    /// A corrupt snapshot can carry a number no `Int` holds; `Int(d)` trapped on it.
    func testAsIntRejectsDoublesOutsideIntRange() {
        let report = makeReport()
        let outOfRange: [Double] = [
            1e300, -1e300, .nan, .infinity, -.infinity, 9.3e18, -9.3e18,
        ]
        for value in outOfRange {
            XCTAssertNil(report.asInt(value), "\(value) must read as nil, not trap")
        }
    }

    func testAsIntRoundsFractionalDoubles() {
        let report = makeReport()
        XCTAssertEqual(report.asInt(3.7), 4)
        XCTAssertEqual(report.asInt(-2.4), -2)
        XCTAssertEqual(report.asInt(12.0), 12)
    }

    /// The OS bars read counts through asInt; a corrupt one must not take the report down.
    func testOSChartSurvivesCorruptOSCount() {
        let report = makeReport()
        let html = report.buildOSChart(osVersions: [
            ["os_version": "15.1", "count": 1e300],
            ["os_version": "15.2", "count": 4],
        ]).html
        XCTAssertTrue(html.contains("15.2: 4 devices"), "a valid count survives")
        XCTAssertTrue(html.contains("15.1: 0 devices"), "a corrupt count reads as 0")
    }

    /// Most Macs first, and "26.7" and "26.7.0" are one row.
    func testOSChartListsTheMostMacsFirstWithEachReleaseOnce() throws {
        let html = makeReport().buildOSChart(osVersions: [
            ["os_version": "15.7.3", "count": 6],
            ["os_version": "26.7", "count": 5],
            ["os_version": "26.7.0", "count": 4],
        ]).html
        let first = try XCTUnwrap(html.range(of: "26.7: 9 devices"))
        let second = try XCTUnwrap(html.range(of: "15.7.3: 6 devices"))
        XCTAssertLessThan(first.lowerBound, second.lowerBound)
        XCTAssertFalse(html.contains("26.7.0"))
    }

    // MARK: - Task 1: Compliance tile

    func testComplianceTileRendersCorrectPercentage() {
        let report = makeReport()
        // 87 passing, 13 failing out of 100 → 87%
        let compliance: [[String: Any]] = (0..<87).map { _ in ["failure_count": 0] }
            + (0..<13).map { _ in ["failure_count": 3] }
        let html = report.buildComplianceTile(deviceCompliance: compliance)
        XCTAssertTrue(html.contains("compliance-hero"), "Should render hero tile")
        XCTAssertTrue(html.contains("87%"), "Should show 87% pass rate")
        XCTAssertTrue(html.contains("13 of 100"), "Should show 13 of 100 failing")
    }

    /// jamf-cli's device-compliance rows carry no failure count. Reading the missing count
    /// as zero put "100% Device Compliance" on a fleet with security gaps.
    func testComplianceTileAbsentWhenRowsCarryNoFailureCount() {
        let report = makeReport()
        let rows: [[String: Any]] = (0..<5).map {
            ["name": "Test-Mac-\($0)", "serial": "S\($0)", "managed": true, "stale": false,
             "days_since_contact": "3"]
        }
        XCTAssertTrue(report.buildComplianceTile(deviceCompliance: rows).isEmpty)
    }

    func testComplianceTileAbsentWhenSnapshotMissing() {
        let report = makeReport()
        let html = report.buildComplianceTile(deviceCompliance: [])
        XCTAssertTrue(html.isEmpty, "Should produce empty string when no data")
    }

    func testComplianceTileGreenAt95Pct() {
        let report = makeReport()
        let compliance: [[String: Any]] = (0..<95).map { _ in ["failure_count": 0] }
            + (0..<5).map { _ in ["failure_count": 1] }
        let html = report.buildComplianceTile(deviceCompliance: compliance)
        XCTAssertTrue(html.contains("compliance-hero-green"))
    }

    func testComplianceTileAmberBetween80And95() {
        let report = makeReport()
        let compliance: [[String: Any]] = (0..<85).map { _ in ["failure_count": 0] }
            + (0..<15).map { _ in ["failure_count": 1] }
        let html = report.buildComplianceTile(deviceCompliance: compliance)
        XCTAssertTrue(html.contains("compliance-hero-amber"))
    }

    func testComplianceTileRedBelow80() {
        let report = makeReport()
        let compliance: [[String: Any]] = (0..<70).map { _ in ["failure_count": 0] }
            + (0..<30).map { _ in ["failure_count": 2] }
        let html = report.buildComplianceTile(deviceCompliance: compliance)
        XCTAssertTrue(html.contains("compliance-hero-red"))
    }

    // MARK: - Task 2: Top non-compliant devices table

    func testTopNonCompliantTableAbsentWhenNoFailures() {
        let report = makeReport()
        let passing: [[String: Any]] = (0..<5).map { _ in ["failure_count": 0, "name": "Mac"] }
        let html = report.buildTopNonCompliantTable(deviceCompliance: passing, computersInventory: [])
        XCTAssertTrue(html.isEmpty)
    }

    func testTopNonCompliantTableAbsentWhenSnapshotEmpty() {
        let report = makeReport()
        let html = report.buildTopNonCompliantTable(deviceCompliance: [], computersInventory: [])
        XCTAssertTrue(html.isEmpty)
    }

    func testTopNonCompliantTableRendersSortedTop10() {
        let report = makeReport()
        // 15 failing devices with varying failure counts
        var devices: [[String: Any]] = (1...15).map { i -> [String: Any] in
            ["name": "Mac-\(i)", "failure_count": i, "serial_number": "SN\(i)",
             "last_check_in": "2026-01-01T00:00:00Z"]
        }
        // Add some passing
        devices += (0..<5).map { _ in ["failure_count": 0, "name": "GoodMac"] }

        let html = report.buildTopNonCompliantTable(
            deviceCompliance: devices,
            computersInventory: []
        )
        XCTAssertTrue(html.contains("Top non-compliant devices (15)"))
        let (shown, rest) = HtmlSectionTests.splitAtShowAll(html)
        // Mac-15 has the highest failure count and should appear first
        XCTAssertTrue(shown.contains("Mac-15"))
        // Mac-1 has the lowest: it is not among the top ten shown, but stays behind Show all.
        XCTAssertFalse(shown.contains("<td>Mac-1</td>"),
                       "Mac-1 (lowest count) is not in the top 10")
        XCTAssertTrue(rest.contains("<td>Mac-1</td>"))
        // Table should have the 5 required columns
        XCTAssertTrue(html.contains("Device Name"))
        XCTAssertTrue(html.contains("Serial"))
        XCTAssertTrue(html.contains("Days Since Check-in"))
        XCTAssertTrue(html.contains("Failure Count"))
        XCTAssertTrue(html.contains("Top Failure"))
    }

    func testTopNonCompliantTableMaxTenRows() {
        let report = makeReport()
        let devices: [[String: Any]] = (1...20).map { i -> [String: Any] in
            ["name": "Mac-\(i)", "failure_count": i]
        }
        let html = report.buildTopNonCompliantTable(
            deviceCompliance: devices,
            computersInventory: []
        )
        let (shown, rest) = HtmlSectionTests.splitAtShowAll(html)
        XCTAssertEqual(HtmlSectionTests.bodyRows(shown), 10, "ten rows show")
        XCTAssertEqual(HtmlSectionTests.bodyRows(rest), 10, "the other ten sit behind Show all")
    }

    // MARK: - Task 3: Light mode default + print CSS

    func testLightModeIsDefault() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = makeReport(dataDir: dir)
        let outputURL = dir.appendingPathComponent("report.html")
        // Generate a minimal report
        try await report.generate(outputURL: outputURL)
        let html = try String(contentsOf: outputURL, encoding: .utf8)
        // The <html> element's initial data-theme attribute must be "light".
        // Dark-mode CSS selectors (`[data-theme="dark"] {...}`) and the JS toggle
        // script will reference "dark" as a string — those are expected and not
        // a violation of the default.
        XCTAssertTrue(html.contains("<html lang=\"en\" data-theme=\"light\""),
                      "Default data-theme on <html> should be light")
        XCTAssertFalse(html.contains("<html lang=\"en\" data-theme=\"dark\""),
                       "<html> element must not initialize with dark theme")
    }

    func testPrintMediaQueryPresent() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outputURL = dir.appendingPathComponent("report.html")
        try await makeReport(dataDir: dir).generate(outputURL: outputURL)
        let html = try String(contentsOf: outputURL, encoding: .utf8)
        let printRange = try XCTUnwrap(html.range(of: "@media print"),
                                       "Print media query must be present in CSS")
        XCTAssertTrue(html[printRange.upperBound...].contains("background: #fff"),
                      "Print CSS must force white background")
    }

    /// The CSS rule for `selector` (its declarations), or nil.
    private func declarations(of selector: String, in css: String) -> String? {
        guard let start = css.range(of: "\n        \(selector) {")
                ?? css.range(of: "\n\(selector) {"),
              let end = css[start.upperBound...].firstIndex(of: "}") else { return nil }
        return String(css[start.upperBound..<end])
    }

    /// A compliance label can be a reverse-DNS name with no space to wrap at; the tiles break
    /// it inside the card, and the AI caption sits in a spaced block.
    func testScreenCSSWrapsLongTileLabelsAndSpacesTheAICaption() throws {
        let css = makeReport().buildCSS(accentColor: "#2D5EA2")
        for selector in [".glance-label", ".tile-label", ".count-label"] {
            let rule = try XCTUnwrap(declarations(of: selector, in: css), selector)
            XCTAssertTrue(rule.contains("overflow-wrap: anywhere"), "\(selector): \(rule)")
        }
        XCTAssertNotNil(declarations(of: ".ai-note", in: css))
        let block = try XCTUnwrap(declarations(of: ".summary-block", in: css))
        XCTAssertTrue(block.contains("margin-bottom"), "the AI summary needs room below it")
    }

    func testLocalStorageThemePersistenceInScript() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = makeReport(dataDir: dir)
        let outputURL = dir.appendingPathComponent("report.html")
        try await report.generate(outputURL: outputURL)
        let html = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(html.contains("localStorage"), "Theme toggle must persist via localStorage")
    }

    // MARK: - daysAgo helper

    func testDaysAgoFromISODate() {
        let report = makeReport()
        // Yesterday
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let days = report.daysAgo(from: iso.string(from: yesterday))
        XCTAssertEqual(days, 1)
    }

    func testDaysAgoFromEmptyStringReturnsNegative() {
        let report = makeReport()
        XCTAssertEqual(report.daysAgo(from: ""), -1)
    }

    func testDaysAgoFromUnparseable() {
        let report = makeReport()
        XCTAssertEqual(report.daysAgo(from: "not-a-date"), -1)
    }

    // MARK: - Charts are HTML

    /// A workspace with one patch-status snapshot, which gives the report a chart.
    private func chartDataDir() throws -> URL {
        let dir = try makeTempDir()
        let kind = dir.appendingPathComponent("patch-status", isDirectory: true)
        try FileManager.default.createDirectory(at: kind, withIntermediateDirectories: true)
        let rows: [[String: Any]] = [["title": "Zoom", "on_latest": 5, "on_other": 1,
                                      "total": 6, "compliance_pct": "83%", "latest": "6.0"]]
        try JSONSerialization.data(withJSONObject: rows)
            .write(to: kind.appendingPathComponent("patch-status_20260401T000000.json"))
        return dir
    }

    /// The patch chart is bars in HTML and CSS: no canvas, no chart library, no 200 KB.
    func testPatchChartIsDrawnInHTMLWithNoLibrary() async throws {
        let dir = try chartDataDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outputURL = dir.appendingPathComponent("report.html")
        try await makeReport(dataDir: dir).generate(outputURL: outputURL)
        let html = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(html.contains("id=\"patch-chart\""))
        XCTAssertTrue(html.contains("Zoom: 83%"))
        XCTAssertTrue(html.contains("width:83%"))
        for absent in ["<canvas", "new Chart", "chart.umd", "window.Chart"] {
            XCTAssertFalse(html.contains(absent), absent)
        }
        XCTAssertLessThan(html.utf8.count, 60_000)
    }

    func testNoCDNReferenceInOutput() async throws {
        let dir = try chartDataDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outputURL = dir.appendingPathComponent("report.html")
        try await makeReport(dataDir: dir).generate(outputURL: outputURL)
        let html = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertFalse(html.contains("cdn.jsdelivr.net"), "the report loads nothing from a CDN")
        XCTAssertFalse(html.contains("<script src"), "and no script from anywhere")
    }

    /// A chart label is page text: a title holding markup arrives escaped, so it cannot
    /// open a script or a comment that hides the rest of the report.
    func testChartLabelsAreEscapedAsHTML() {
        let report = makeReport()
        let patch = report.buildPatchChart(patchStatus: [
            ["title": "</script><script>alert('xss')</script>", "compliance_pct": "100%"],
        ]).html
        let os = report.buildOSChart(osVersions: [["os_version": "15.1 <!-- <b>", "count": 2]]).html
        for html in [patch, os] {
            for raw in ["<script", "</script", "<!--", "<b>"] {
                XCTAssertFalse(html.contains(raw), "raw \(raw) in \(html)")
            }
        }
        XCTAssertTrue(patch.contains("&lt;/script&gt;&lt;script&gt;alert(&#39;xss&#39;)"))
        XCTAssertTrue(os.contains("15.1 &lt;!-- &lt;b&gt;"))
    }

    // MARK: - Summary tiles under the security policy

    private struct RenderedTile {
        let cssClass: String
        let value: String
        let label: String
        let block: String
    }

    /// A temp data dir holding the real-shape `security` fixture (101 Macs; FileVault 100,
    /// SIP 1, Firewall 0, Gatekeeper 100) or `security` JSON given inline.
    private func securityDataDir(
        json: Data? = nil, computers: [[String: Any]]? = nil
    ) throws -> URL {
        let dir = try makeTempDir()
        let securityDir = dir.appendingPathComponent("security", isDirectory: true)
        try FileManager.default.createDirectory(at: securityDir, withIntermediateDirectories: true)
        let data = try json ?? Data(contentsOf: TestFixtures.root
            .appendingPathComponent("jamf-cli-data/security/security.json"))
        try data.write(to: securityDir.appendingPathComponent("security.json"))
        if let computers {
            let computersDir = dir.appendingPathComponent("computers", isDirectory: true)
            try FileManager.default.createDirectory(
                at: computersDir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: computers)
                .write(to: computersDir.appendingPathComponent("computers.json"))
        }
        return dir
    }

    /// Both callers of the tiles: the full report (`sections: nil`) and a template that lists
    /// only the security controls.
    private func renderedTiles(
        yaml: String = "", dataDir: URL, templated: Bool
    ) async throws -> [RenderedTile] {
        let config = try ConfigLoader.loadFromString(yaml).withDefaults()
        let outputURL = dataDir.appendingPathComponent("report-\(UUID().uuidString).html")
        try await HtmlReport(config: config, dataDir: dataDir).generate(
            outputURL: outputURL, sections: templated ? [.securityTiles] : nil)
        let html = try String(contentsOf: outputURL, encoding: .utf8)
        let start = try XCTUnwrap(html.range(of: "<section class=\"tiles-row\">"))
        let end = try XCTUnwrap(html.range(
            of: "</section>", range: start.upperBound..<html.endIndex))
        func inner(_ block: String, _ marker: String) -> String {
            guard let open = block.range(of: marker),
                  let close = block.range(of: "</div>", range: open.upperBound..<block.endIndex)
            else { return "" }
            return String(block[open.upperBound..<close.lowerBound])
        }
        return String(html[start.upperBound..<end.lowerBound])
            .components(separatedBy: "<div class=\"tile ").dropFirst().map { block in
                RenderedTile(
                    cssClass: String(block.prefix { $0 != "\"" }),
                    value: inner(block, "<div class=\"tile-value\">"),
                    label: inner(block, "<div class=\"tile-label\">"), block: block)
            }
    }

    func testSummaryTileClassesOnTheSecurityFixture() async throws {
        let dir = try securityDataDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for templated in [false, true] {
            let tiles = try await renderedTiles(dataDir: dir, templated: templated)
            XCTAssertEqual(tiles.map(\.label),
                           ["Total Devices", "FileVault", "SIP", "Firewall", "Gatekeeper"])
            XCTAssertEqual(tiles.map(\.value), ["101", "99.0%", "1.0%", "0.0%", "99.0%"])
            // SIP is NOT_COLLECTED on 100 of the 101 rows: the one Mac that reported it is on.
            XCTAssertEqual(tiles.map(\.cssClass), ["", "ok", "ok", "bad", "ok"],
                           "templated: \(templated)")
        }
    }

    /// An ignored control gets no colour and says so. SIP at warning has no Mac to warn about on
    /// this fixture: the 100 that did not report it are neither. The tile values stay the facts.
    func testSummaryTilesFollowThePolicy() async throws {
        let dir = try securityDataDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for templated in [false, true] {
            let tiles = try await renderedTiles(yaml: """
            security_policy:
              controls:
                sip: warning
                firewall: ignore
            """, dataDir: dir, templated: templated)
            XCTAssertEqual(tiles.map(\.label), [
                "Total Devices", "FileVault", "SIP", "Firewall (not counted)", "Gatekeeper",
            ])
            XCTAssertEqual(tiles.map(\.value), ["101", "99.0%", "1.0%", "0.0%", "99.0%"])
            XCTAssertEqual(tiles.map(\.cssClass), ["", "ok", "ok", "", "ok"],
                           "templated: \(templated)")
        }
    }

    /// `encrypted` Macs with FileVault on, then `silicon` Apple silicon and `intel` Intel Macs
    /// with it off; by default ten Macs, seven on and three Apple silicon off.
    private func hardwareTilesDir(
        encrypted: Int = 7, silicon: Int = 3, intel: Int = 0
    ) throws -> URL {
        func device(_ name: String, _ serial: String, _ fileVault: String) -> [String: Any] {
            ["section": "device", "name": name, "serial": serial, "os_version": "15.4.1",
             "filevault": fileVault, "sip": "ENABLED", "firewall": true,
             "gatekeeper": "APP_STORE"]
        }
        let total = encrypted + silicon + intel
        var items: [[String: Any]] = [["section": "summary", "data": [
            "total_devices": total, "filevault_encrypted": encrypted, "sip_enabled": total,
            "firewall_enabled": total, "gatekeeper_enabled": total,
        ]]]
        var computers: [[String: Any]] = []
        for n in 0..<encrypted { items.append(device("on\(n)", "ON\(n)", "ENCRYPTED")) }
        for n in 0..<silicon {
            items.append(device("as\(n)", "AS\(n)", "UNENCRYPTED"))
            computers.append(["general": ["name": "as\(n)"],
                              "hardware": ["serialNumber": "AS\(n)", "appleSilicon": true]])
        }
        for n in 0..<intel {
            items.append(device("in\(n)", "IN\(n)", "UNENCRYPTED"))
            computers.append(["general": ["name": "in\(n)"],
                              "hardware": ["serialNumber": "IN\(n)", "appleSilicon": false,
                                           "modelIdentifier": "MacBookPro14,1"]])
        }
        return try securityDataDir(
            json: JSONSerialization.data(withJSONObject: items), computers: computers)
    }

    func testFileVaultTileNamesHardwareEncryptedMacsWithFileVaultOff() async throws {
        let dir = try hardwareTilesDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let extra = "<div class=\"tile-label\">3 more hardware-encrypted, FileVault off</div>"
        for templated in [false, true] {
            let none = try await renderedTiles(dataDir: dir, templated: templated)
            XCTAssertEqual(none[1].cssClass, "bad")
            XCTAssertFalse(none[1].block.contains("hardware-encrypted"))

            let warning = try await renderedTiles(
                yaml: "security_policy:\n  filevault_off_hardware_encrypted: warning\n",
                dataDir: dir, templated: templated)
            XCTAssertEqual(warning[1].value, "70.0%", "the fact")
            XCTAssertEqual(warning[1].cssClass, "warn", "no Mac fails it, but three only warn")
            XCTAssertTrue(warning[1].block.contains(extra), "templated: \(templated)")

            let ignore = try await renderedTiles(
                yaml: "security_policy:\n  filevault_off_hardware_encrypted: ignore\n",
                dataDir: dir, templated: templated)
            XCTAssertEqual(ignore[1].cssClass, "ok")
            XCTAssertTrue(ignore[1].block.contains(extra))
            XCTAssertFalse(ignore[2].block.contains("hardware-encrypted"),
                           "only the FileVault tile")
        }
    }

    /// A hardware level stricter than FileVault's makes those Macs plain failures, so no
    /// tile names them apart.
    func testFileVaultTileDoesNotNameMacsTheRuleMakesFailures() async throws {
        let dir = try hardwareTilesDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tiles = try await renderedTiles(yaml: """
        security_policy:
          controls:
            filevault: warning
          filevault_off_hardware_encrypted: fail
        """, dataDir: dir, templated: false)
        XCTAssertEqual(tiles[1].cssClass, "bad")
        XCTAssertFalse(tiles[1].block.contains("hardware-encrypted"))
    }

    /// Ten Macs, five encrypted, three Apple silicon and two Intel off, hardware level at
    /// `ignore`: the tile reads the 5 of 7 Macs counted (71.4%, bad), as the workbook does.
    /// The value stays the fact, 5 of 10.
    func testFileVaultTileGradesOverTheMacsThatAreCounted() async throws {
        let dir = try hardwareTilesDir(encrypted: 5, silicon: 3, intel: 2)
        defer { try? FileManager.default.removeItem(at: dir) }
        for templated in [false, true] {
            let tiles = try await renderedTiles(
                yaml: "security_policy:\n  filevault_off_hardware_encrypted: ignore\n",
                dataDir: dir, templated: templated)
            XCTAssertEqual(tiles[1].value, "50.0%")
            XCTAssertEqual(tiles[1].cssClass, "bad", "templated: \(templated)")
        }
    }

    /// Every Mac with FileVault off is hardware-encrypted and not counted, and none is on:
    /// no Mac is left to grade, so the tile has no colour rather than a red one.
    func testFileVaultTileHasNoColourWhenNoMacIsCounted() async throws {
        let dir = try hardwareTilesDir(encrypted: 0, silicon: 2, intel: 0)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tiles = try await renderedTiles(
            yaml: "security_policy:\n  filevault_off_hardware_encrypted: ignore\n",
            dataDir: dir, templated: false)
        XCTAssertEqual(tiles[1].cssClass, "")
        XCTAssertEqual(tiles[2].cssClass, "ok", "the other tiles still grade")
    }
}
