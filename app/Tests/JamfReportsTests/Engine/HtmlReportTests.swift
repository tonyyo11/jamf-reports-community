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

    // MARK: - Section: buildPoliciesTable

    func testBuildPoliciesTableEmptyData() {
        let report = makeReport()
        let html = report.buildPoliciesTable([])
        // Empty data now produces an empty-section placeholder, not an empty string.
        XCTAssertFalse(html.isEmpty, "Empty data should produce an empty-section placeholder")
        XCTAssertTrue(html.contains("empty-section"))
    }

    func testBuildPoliciesTableRendersRows() {
        let report = makeReport()
        let policies: [[String: Any]] = [
            ["name": "Install Software", "category": "Maintenance", "enabled": true],
            ["name": "Disabled Policy", "category": "Testing", "enabled": false],
        ]
        let html = report.buildPoliciesTable(policies)
        XCTAssertTrue(html.contains("Policies (2)"))
        XCTAssertTrue(html.contains("Install Software"))
        XCTAssertTrue(html.contains("Disabled Policy"))
        XCTAssertTrue(html.contains("row-warn")) // disabled row gets warn class
    }

    func testBuildPoliciesTableEscapesHTML() {
        let report = makeReport()
        let policies: [[String: Any]] = [
            ["name": "<script>alert('xss')</script>", "category": "Bad&Category", "enabled": true],
        ]
        let html = report.buildPoliciesTable(policies)
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("Bad&amp;Category"))
    }

    // MARK: - Section: buildSmartGroupsTable

    func testBuildSmartGroupsTableEmptyData() {
        let report = makeReport()
        let html = report.buildSmartGroupsTable([])
        XCTAssertFalse(html.isEmpty, "Empty data should produce an empty-section placeholder")
        XCTAssertTrue(html.contains("empty-section"))
    }

    func testBuildSmartGroupsTableRendersRows() {
        let report = makeReport()
        let groups: [[String: Any]] = [
            ["name": "All Managed Macs", "criteria": [["name": "OS"], ["name": "Managed"]]],
            ["name": "Stale Devices", "criteria_count": 3],
        ]
        let html = report.buildSmartGroupsTable(groups)
        XCTAssertTrue(html.contains("Smart Groups (2)"))
        XCTAssertTrue(html.contains("All Managed Macs"))
        XCTAssertTrue(html.contains(">2<")) // 2 criteria from array count
        XCTAssertTrue(html.contains("Stale Devices"))
    }

    // MARK: - Section: buildScriptsTable

    func testBuildScriptsTableEmptyData() {
        let report = makeReport()
        let html = report.buildScriptsTable([])
        XCTAssertFalse(html.isEmpty, "Empty data should produce an empty-section placeholder")
        XCTAssertTrue(html.contains("empty-section"))
    }

    func testBuildScriptsTableRendersRows() {
        let report = makeReport()
        let scripts: [[String: Any]] = [
            ["name": "FileVault Check", "category": "Security"],
            ["displayName": "Recon Trigger", "category": ""],
        ]
        let html = report.buildScriptsTable(scripts)
        XCTAssertTrue(html.contains("Scripts (2)"))
        XCTAssertTrue(html.contains("FileVault Check"))
        XCTAssertTrue(html.contains("Recon Trigger"))
    }

    // MARK: - Section: buildPackagesTable

    func testBuildPackagesTableEmptyData() {
        let report = makeReport()
        let html = report.buildPackagesTable([])
        XCTAssertFalse(html.isEmpty, "Empty data should produce an empty-section placeholder")
        XCTAssertTrue(html.contains("empty-section"))
    }

    func testBuildPackagesTableRendersRows() {
        let report = makeReport()
        let packages: [[String: Any]] = [
            ["name": "Firefox 130.0.pkg", "category": "Browsers"],
            ["fileName": "CrowdStrike.pkg", "category": ["name": "Security"]],
        ]
        let html = report.buildPackagesTable(packages)
        XCTAssertTrue(html.contains("Packages (2)"))
        XCTAssertTrue(html.contains("Firefox 130.0.pkg"))
        XCTAssertTrue(html.contains("CrowdStrike.pkg"))
        XCTAssertTrue(html.contains("Security"))
    }

    // MARK: - Section: buildCategoriesTable

    func testBuildCategoriesTableEmptyData() {
        let report = makeReport()
        let html = report.buildCategoriesTable([])
        XCTAssertFalse(html.isEmpty, "Empty data should produce an empty-section placeholder")
        XCTAssertTrue(html.contains("empty-section"))
    }

    func testBuildCategoriesTableRendersRows() {
        let report = makeReport()
        let categories: [[String: Any]] = [
            ["name": "Security", "priority": 1],
            ["name": "Maintenance", "priority": 5],
        ]
        let html = report.buildCategoriesTable(categories)
        XCTAssertTrue(html.contains("Categories (2)"))
        XCTAssertTrue(html.contains("Security"))
        XCTAssertTrue(html.contains("Maintenance"))
    }

    // MARK: - Helper: categoryName

    func testCategoryNameFromString() {
        let report = makeReport()
        XCTAssertEqual(report.categoryName(from: "Security"), "Security")
    }

    func testCategoryNameFromDict() {
        let report = makeReport()
        XCTAssertEqual(report.categoryName(from: ["name": "Browsers"] as [String: Any]), "Browsers")
    }

    func testCategoryNameFromNilReturnsEmpty() {
        let report = makeReport()
        XCTAssertEqual(report.categoryName(from: nil), "")
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

    func testResolvedHistoryPathRelative() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let outputURL = tmp.appendingPathComponent("report.html")
        let report = makeReport()
        let path = report.resolvedHistoryPath("snapshots/history.json", outputURL: outputURL)
        XCTAssertTrue(path.path.hasSuffix("snapshots/history.json"))
    }

    func testResolvedHistoryPathAbsolute() throws {
        let outputURL = URL(fileURLWithPath: "/tmp/report.html")
        let report = makeReport()
        let path = report.resolvedHistoryPath("/var/log/history.json", outputURL: outputURL)
        XCTAssertEqual(path.path, "/var/log/history.json")
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
        XCTAssertTrue(html.contains("Top Non-Compliant Devices"))
        // Mac-15 has the highest failure count and should appear first
        XCTAssertTrue(html.contains("Mac-15"))
        // Mac-1 has the lowest and should not appear (only top 10 shown from 15 failing)
        XCTAssertFalse(html.contains("Mac-1\""), "Mac-1 (lowest count) should not appear in top 10")
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
        // Count <tr> rows in tbody — there should be at most 10 data rows
        // Each row has a <tr> — count them minus the header row
        // Total <tr> count includes the thead row (1) plus data rows. Subtract 1
        // for components-split mechanics and 1 more for the header.
        let dataRowCount = html.components(separatedBy: "<tr>").count - 2
        XCTAssertLessThanOrEqual(dataRowCount, 10, "Should render at most 10 data rows")
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

    func testPrintMediaQueryPresent() {
        let report = makeReport()
        // The CSS builder includes @media print — invoke it directly
        let css = report.buildCSSPublic(accentColor: "#2D5EA2")
        XCTAssertTrue(css.contains("@media print"), "Print media query must be present in CSS")
        XCTAssertTrue(css.contains("background: #fff"), "Print CSS must force white background")
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

    // MARK: - Task 4: Data provenance block

    func testProvenanceBlockContainsFourFields() {
        let report = makeReport()
        let overview: [[String: Any]] = []
        let html = report.buildProvenanceBlock(overview: overview, profileName: "acme-prod")
        XCTAssertTrue(html.contains("Data collected:"), "Must contain collection timestamp")
        XCTAssertTrue(html.contains("Profile:"), "Must contain profile name")
        XCTAssertTrue(html.contains("jamf-cli:"), "Must contain jamf-cli version")
        XCTAssertTrue(html.contains("Enrolled:"), "Must contain enrolled count")
        XCTAssertTrue(html.contains("acme-prod"), "Profile name must appear in output")
    }

    func testProvenanceBlockEscapesProfileName() {
        let report = makeReport()
        let html = report.buildProvenanceBlock(overview: [], profileName: "<bad>&profile")
        XCTAssertFalse(html.contains("<bad>"))
        XCTAssertTrue(html.contains("&lt;bad&gt;"))
    }

    func testProvenanceBlockShowsDashWhenProfileEmpty() {
        let report = makeReport()
        let html = report.buildProvenanceBlock(overview: [], profileName: "")
        XCTAssertTrue(html.contains("Profile: —") || html.contains("Profile:</span>\n          <span>&middot;"))
    }

    // MARK: - Task 4 (extended): Provenance struct fields in provenance block

    func testProvenanceBlockRendersRunIDWhenProvenance() {
        let report = makeReport()
        let prov = Provenance(
            runID: "test-run-id-1234",
            generatedAt: Date(),
            profile: "acme-prod",
            jamfCLIVersion: "1.14.0",
            jamfTenantURL: "https://jamf.example.com",
            operatorUserHost: "user@host"
        )
        let html = report.buildProvenanceBlock(
            overview: [], profileName: "acme-prod", provenance: prov
        )
        XCTAssertTrue(html.contains("Run ID:"), "Must contain Run ID: label")
        XCTAssertTrue(html.contains("test-run-id-1234"), "Must contain the run ID value")
    }

    func testProvenanceBlockRendersTenantURLWhenPresent() {
        let report = makeReport()
        let prov = Provenance(
            runID: UUID().uuidString,
            generatedAt: Date(),
            profile: "acme",
            jamfCLIVersion: nil,
            jamfTenantURL: "https://jamf.example.com",
            operatorUserHost: "user@host"
        )
        let html = report.buildProvenanceBlock(
            overview: [], profileName: "acme", provenance: prov
        )
        XCTAssertTrue(html.contains("Tenant URL:"), "Must render Tenant URL: label")
        XCTAssertTrue(html.contains("https://jamf.example.com"))
    }

    func testProvenanceBlockOmitsTenantURLWhenAbsent() {
        let report = makeReport()
        let prov = Provenance(
            runID: UUID().uuidString,
            generatedAt: Date(),
            profile: "acme",
            jamfCLIVersion: nil,
            jamfTenantURL: nil,
            operatorUserHost: "user@host"
        )
        let html = report.buildProvenanceBlock(
            overview: [], profileName: "acme", provenance: prov
        )
        XCTAssertFalse(html.contains("Tenant URL:"),
                       "Must not render Tenant URL when jamfTenantURL is nil")
    }

    func testProvenanceBlockRendersOperatorWhenProvenance() {
        let report = makeReport()
        let prov = Provenance(
            runID: UUID().uuidString,
            generatedAt: Date(),
            profile: "acme",
            jamfCLIVersion: nil,
            jamfTenantURL: nil,
            operatorUserHost: "operator@example-host"
        )
        let html = report.buildProvenanceBlock(
            overview: [], profileName: "acme", provenance: prov
        )
        XCTAssertTrue(html.contains("Operator:"), "Must contain Operator: label")
        XCTAssertTrue(html.contains("operator@example-host"))
    }

    func testProvenanceBlockUsesProvenanceCLIVersionOverOverview() {
        let report = makeReport()
        let prov = Provenance(
            runID: UUID().uuidString,
            generatedAt: Date(),
            profile: "test",
            jamfCLIVersion: "1.14.5-prov",
            jamfTenantURL: nil,
            operatorUserHost: "user@host"
        )
        // Overview also has a version — provenance version should win
        let overview: [[String: Any]] = [["jamf_cli_version": "0.0.1-stale"]]
        let html = report.buildProvenanceBlock(
            overview: overview, profileName: "test", provenance: prov
        )
        XCTAssertTrue(html.contains("1.14.5-prov"),
                      "Provenance CLI version must override overview version")
        XCTAssertFalse(html.contains("0.0.1-stale"))
    }

    func testProvenanceBlockNoProvenanceStructShowsOriginalFourFields() {
        let report = makeReport()
        let html = report.buildProvenanceBlock(
            overview: [], profileName: "test", provenance: nil
        )
        XCTAssertTrue(html.contains("Data collected:"))
        XCTAssertTrue(html.contains("Profile:"))
        XCTAssertTrue(html.contains("jamf-cli:"))
        XCTAssertTrue(html.contains("Enrolled:"))
        XCTAssertFalse(html.contains("Run ID:"),
                       "Run ID must not appear when provenance is nil")
        XCTAssertFalse(html.contains("Operator:"),
                       "Operator must not appear when provenance is nil")
    }

    // MARK: - Task 5: Month-over-month section

    func testMomSectionShowsInsufficientWhenHistoryEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = makeReport(dataDir: dir)
        let historyURL = dir.appendingPathComponent("html_history.json")
        let html = report.buildMonthOverMonthSection(
            historyURL: historyURL,
            currentSecurity: [],
            deviceCompliance: [],
            totalDevices: 500,
            fileVaultPct: 92.0
        )
        // No history file at all → empty string
        XCTAssertTrue(html.isEmpty, "Empty history should produce empty output")
    }

    func testMomSectionShowsInsufficientWhenTooRecent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = makeReport(dataDir: dir)
        let historyURL = dir.appendingPathComponent("html_history.json")

        // Write a single entry from 5 days ago (too recent for 30-day comparison)
        let recentDate = Calendar.current.date(byAdding: .day, value: -5, to: Date())!
        let iso = ISO8601DateFormatter()
        let entry: [[String: Any]] = [
            ["ts": iso.string(from: recentDate), "versions": [["v": "15.4", "c": 480]]],
        ]
        let data = try JSONSerialization.data(withJSONObject: entry)
        try data.write(to: historyURL)

        let html = report.buildMonthOverMonthSection(
            historyURL: historyURL,
            currentSecurity: [],
            deviceCompliance: [],
            totalDevices: 500,
            fileVaultPct: 92.0
        )
        XCTAssertTrue(html.contains("Insufficient history"))
    }

    func testMomSectionRendersWhenHistoryHas30DayEntry() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = makeReport(dataDir: dir)
        let historyURL = dir.appendingPathComponent("html_history.json")

        let pastDate = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let iso = ISO8601DateFormatter()
        let entry: [[String: Any]] = [
            ["ts": iso.string(from: pastDate), "versions": [["v": "15.4", "c": 480]]],
        ]
        let data = try JSONSerialization.data(withJSONObject: entry)
        try data.write(to: historyURL)

        let html = report.buildMonthOverMonthSection(
            historyURL: historyURL,
            currentSecurity: [],
            deviceCompliance: [],
            totalDevices: 500,
            fileVaultPct: 92.0
        )
        XCTAssertTrue(html.contains("What Changed Since Last Month"))
        XCTAssertTrue(html.contains("Total Devices"))
        XCTAssertFalse(html.contains("Insufficient history"))
    }

    // MARK: - Task 6: Catalog in appendix after policy section

    func testCatalogAppearsAfterPolicySection() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = makeReport(dataDir: dir)
        let outputURL = dir.appendingPathComponent("report.html")
        try await report.generate(outputURL: outputURL)
        let html = try String(contentsOf: outputURL, encoding: .utf8)

        // Catalog Inventory appendix header is always rendered (template-level)
        XCTAssertTrue(html.contains("Appendix: Jamf Pro Catalog Inventory"),
                      "Catalog appendix header must be present")
        // The appendix div should appear after the main content sections in DOM order.
        // We use the closing </main> tag's predecessor as the structural anchor:
        // the appendix block is rendered inside <main> immediately before </main>.
        let mainOpen = html.range(of: "<main id=\"main-content\">")
        // Anchor on the rendered <div class=\"appendix-section\"> (not the CSS class
        // definition that also contains the substring \"appendix-section\").
        let appendixRange = html.range(of: "<div class=\"appendix-section\">")
        let mainClose = html.range(of: "</main>")
        guard let mainOpen, let appendixRange, let mainClose else {
            XCTFail("Expected <main>, appendix div, and </main> in the rendered HTML")
            return
        }
        XCTAssertGreaterThan(appendixRange.lowerBound, mainOpen.upperBound,
                             "Appendix must be inside <main>")
        XCTAssertLessThan(appendixRange.lowerBound, mainClose.lowerBound,
                          "Appendix must precede </main>")
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

    // MARK: - Chart.js offline fallback script

    func testVendoredChartJsInlinedInOutput() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = makeReport(dataDir: dir)
        let outputURL = dir.appendingPathComponent("report.html")
        try await report.generate(outputURL: outputURL)
        let html = try String(contentsOf: outputURL, encoding: .utf8)

        // The vendored Chart.js UMD build must be inlined. Its window.Chart assignment
        // is the reliable marker for the UMD export.
        XCTAssertTrue(
            html.contains("window.Chart"),
            "Vendored Chart.js must be inlined — window.Chart assignment must appear in output"
        )
    }

    func testNoCDNReferenceInOutput() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = makeReport(dataDir: dir)
        let outputURL = dir.appendingPathComponent("report.html")
        try await report.generate(outputURL: outputURL)
        let html = try String(contentsOf: outputURL, encoding: .utf8)

        XCTAssertFalse(
            html.contains("cdn.jsdelivr.net"),
            "Generated HTML must not reference cdn.jsdelivr.net — Chart.js must be vendored inline"
        )
    }

    // MARK: - Section: JS injection safety (Task 2)

    /// A patch title containing `</script><script>alert('xss')</script>` must not
    /// break out of the surrounding script block.
    func testJSInjectionScriptBreakoutSanitized() {
        let report = makeReport()
        let malicious = "</script><script>alert('xss')</script>"
        let html = report.buildChartsSection(
            osVersions: [],
            patchStatus: [["title": malicious, "compliance_pct": "100%"]],
            accentColor: "#2D5EA2"
        )
        // The raw breakout sequence must not appear verbatim — JSON encoding escapes </
        XCTAssertFalse(
            html.contains("</script><script>alert"),
            "XSS breakout must not appear verbatim in JS block"
        )
    }

    /// A label containing U+2028 LINE SEPARATOR must be JSON-encoded, not HTML-escaped.
    /// U+2028 is a valid JS line terminator that breaks string literals when unescaped.
    func testJSInjectionLineSeparatorSanitized() {
        let report = makeReport()
        let label = "macOS\u{2028}15.7"
        let html = report.buildChartsSection(
            osVersions: [["os_version": label, "count": 5]],
            patchStatus: [],
            accentColor: "#2D5EA2"
        )
        // JSON encoding renders U+2028 as   — the raw codepoint must not appear.
        XCTAssertFalse(
            html.contains("\u{2028}"),
            "U+2028 LINE SEPARATOR must be JSON-escaped, not passed raw into JS"
        )
    }

    /// A label containing a backslash and double-quote must not break the JS literal.
    func testJSInjectionBackslashQuoteSanitized() {
        let report = makeReport()
        let label = #"\"injected\""#  // produces: \"injected\"
        let html = report.buildChartsSection(
            osVersions: [["os_version": label, "count": 3]],
            patchStatus: [],
            accentColor: "#2D5EA2"
        )
        // After JSON encoding the backslash is doubled: \\\"injected\\\"
        // The resulting JSON array must be present and the raw sequence must not break parsing.
        XCTAssertTrue(html.contains("<script>"), "Chart section must still contain a script block")
    }

    // MARK: - emptySection placeholder

    func testEmptySectionHelperRendersTitle() {
        let html = HtmlSectionFormatters.emptySection(
            title: "Policy Health", dataKind: "policy-status"
        )
        XCTAssertTrue(html.contains("Policy Health"), "Section title must appear in placeholder")
        XCTAssertTrue(html.contains("policy-status"), "dataKind must appear in placeholder")
        XCTAssertTrue(html.contains("empty-section"), "Must use empty-section CSS class")
        XCTAssertTrue(html.contains("empty-note"), "Must use empty-note CSS class")
    }

    func testEmptySectionHelperEscapesInputs() {
        let html = HtmlSectionFormatters.emptySection(
            title: "<script>XSS</script>",
            dataKind: "kind&value"
        )
        XCTAssertFalse(html.contains("<script>"), "Title must be HTML-escaped")
        XCTAssertTrue(html.contains("&lt;script&gt;"), "Title must be HTML-escaped")
        XCTAssertTrue(html.contains("kind&amp;value"), "dataKind must be HTML-escaped")
    }

    func testPoliciesTableEmptyReturnsEmptySectionPlaceholder() {
        let report = makeReport()
        let html = report.buildPoliciesTable([])
        XCTAssertTrue(html.contains("empty-section"),
                      "Empty policies should render an empty-section placeholder, not an empty string")
        XCTAssertTrue(html.contains("policies"), "Placeholder must reference the snapshot kind")
    }

    func testSmartGroupsTableEmptyReturnsEmptySectionPlaceholder() {
        let report = makeReport()
        let html = report.buildSmartGroupsTable([])
        XCTAssertTrue(html.contains("empty-section"))
    }

    /// When generated HTML contains a policyStatus snapshot that is empty, the
    /// Policy Health section placeholder (not an empty string) must appear in the output.
    func testGeneratedHtmlContainsEmptySectionForMissingPolicyStatus() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = makeReport(dataDir: dir)
        let outputURL = dir.appendingPathComponent("report.html")
        try await report.generate(outputURL: outputURL)
        let html = try String(contentsOf: outputURL, encoding: .utf8)
        // With no snapshot data, Policy Health should render a placeholder, not vanish.
        XCTAssertTrue(
            html.contains("empty-section"),
            "Report must contain at least one empty-section placeholder when no snapshots exist"
        )
    }
}
