import Foundation
import XCTest
@testable import JamfReports

// MARK: - HtmlSectionTests
//
// Tests for the 14 new HTML section renderers in HtmlReport+Sections and
// the shared helpers in HtmlSectionFormatters.

final class HtmlSectionTests: XCTestCase {

    // MARK: - Helpers

    private func makeReport(config: ReportConfig = ReportConfig().withDefaults()) -> HtmlReport {
        HtmlReport(config: config, dataDir: URL(fileURLWithPath: "/tmp/nonexistent"))
    }

    private static let xssPayload = "<script>alert(1)</script>"
    private static let xssEscaped = "&lt;script&gt;alert(1)&lt;/script&gt;"

    // MARK: - HtmlSectionFormatters

    func testEscapeHTMLBasic() {
        XCTAssertEqual(
            HtmlSectionFormatters.escapeHTML("a & b < c > d \"e\""),
            "a &amp; b &lt; c &gt; d &quot;e&quot;"
        )
    }

    func testEscapeHTMLBlocksJavascriptProtocol() {
        XCTAssertEqual(
            HtmlSectionFormatters.escapeHTML("javascript:alert(1)"),
            "[blocked]"
        )
        XCTAssertEqual(
            HtmlSectionFormatters.escapeHTML("JAVASCRIPT:foo"),
            "[blocked]"
        )
    }

    func testEscapeHTMLBlocksDataTextHTML() {
        XCTAssertEqual(
            HtmlSectionFormatters.escapeHTML("data:text/html,<script>"),
            "[blocked]"
        )
    }

    func testEscapeHTMLBlocksJavascriptProtocolWithEmbeddedTab() {
        // "java\tscript:" — a WHATWG URL parser strips the embedded tab and
        // reads this back as a plain javascript: URL.
        XCTAssertEqual(
            HtmlSectionFormatters.escapeHTML("java\tscript:alert(1)"),
            "[blocked]"
        )
    }

    func testEscapeHTMLBlocksJavascriptProtocolWithEmbeddedCRLF() {
        XCTAssertEqual(
            HtmlSectionFormatters.escapeHTML("java\r\nscript:alert(1)"),
            "[blocked]"
        )
    }

    func testRenderTable() {
        let html = HtmlSectionFormatters.renderTable(
            headers: ["Name", "Count"],
            rows: [["Alice", "5"], ["Bob & Carol", "2"]]
        )
        XCTAssertTrue(html.contains("<table"))
        XCTAssertTrue(html.contains("<th>Name</th>"))
        XCTAssertTrue(html.contains("Bob &amp; Carol"))
        XCTAssertFalse(html.contains("Bob & Carol"))
    }

    func testRenderTableXSS() {
        let html = HtmlSectionFormatters.renderTable(
            headers: [Self.xssPayload],
            rows: [[Self.xssPayload]]
        )
        XCTAssertFalse(html.contains("<script>"), "XSS in table headers must be escaped")
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    func testRenderCardGrid() {
        let cards = [
            HtmlSectionFormatters.SectionCard(name: "Total", value: "42", sublabel: "devices"),
            HtmlSectionFormatters.SectionCard(name: "A&B", value: "7"),
        ]
        let html = HtmlSectionFormatters.renderCardGrid(cards: cards)
        XCTAssertTrue(html.contains("count-card"))
        XCTAssertTrue(html.contains("42"))
        XCTAssertTrue(html.contains("A&amp;B"))
    }

    func testRenderCardGridEmpty() {
        XCTAssertEqual(HtmlSectionFormatters.renderCardGrid(cards: []), "")
    }

    func testRenderPercentBar() {
        let html = HtmlSectionFormatters.renderPercentBar(label: "FileVault", fraction: 0.87)
        XCTAssertTrue(html.contains("pct-bar-row"))
        XCTAssertTrue(html.contains("87%"))
        XCTAssertTrue(html.contains("aria-valuenow=\"87\""))
    }

    func testRenderPercentBarClampsRange() {
        let over = HtmlSectionFormatters.renderPercentBar(label: "X", fraction: 1.5)
        XCTAssertTrue(over.contains("width:100%"))
        let under = HtmlSectionFormatters.renderPercentBar(label: "X", fraction: -0.5)
        XCTAssertTrue(under.contains("width:0%"))
    }

    func testRenderSeverityPillKnownValues() {
        XCTAssertTrue(HtmlSectionFormatters.renderSeverityPill("critical").contains("sev-critical"))
        XCTAssertTrue(HtmlSectionFormatters.renderSeverityPill("HIGH").contains("sev-high"))
        XCTAssertTrue(HtmlSectionFormatters.renderSeverityPill("medium").contains("sev-medium"))
        XCTAssertTrue(HtmlSectionFormatters.renderSeverityPill("info").contains("sev-info"))
    }

    func testRenderSeverityPillXSS() {
        let html = HtmlSectionFormatters.renderSeverityPill(Self.xssPayload)
        XCTAssertFalse(html.contains("<script>"))
    }

    func testRenderList() {
        let html = HtmlSectionFormatters.renderList(items: ["Alpha", "Beta & Gamma"])
        XCTAssertTrue(html.contains("<ul"))
        XCTAssertTrue(html.contains("Beta &amp; Gamma"))
        XCTAssertFalse(html.contains("Beta & Gamma"))
    }

    func testRenderListEmpty() {
        XCTAssertEqual(HtmlSectionFormatters.renderList(items: []), "")
    }

    func testEmptyState() {
        let html = HtmlSectionFormatters.emptyState("reason <here>")
        XCTAssertTrue(html.contains("class=\"empty\""))
        XCTAssertTrue(html.contains("reason &lt;here&gt;"))
    }

    // MARK: - execSummary

    func testExecSummaryWithData() {
        let report = makeReport()
        let security: [[String: Any]] = [[
            "section": "summary",
            "data": ["total_devices": 100, "filevault_encrypted": 95,
                     "sip_enabled": 100, "firewall_enabled": 88]
        ]]
        let compliance: [[String: Any]] = [
            ["failure_count": 0], ["failure_count": 0], ["failure_count": 2],
        ]
        let patch: [[String: Any]] = [
            ["title": "Firefox", "compliance_pct": "80%"],
            ["title": "Zoom", "compliance_pct": "100%"],
        ]
        let secData = security.first?["data"] as? [String: Any] ?? [:]
        let html = report.buildExecSummary(
            totalDevices: report.asInt(secData["total_devices"]) ?? 0,
            fileVaultPct: 95,
            sipPct: 100,
            firewallPct: 88,
            deviceCompliance: compliance,
            patchStatus: patch
        )
        XCTAssertTrue(html.contains("exec-summary"))
        XCTAssertTrue(html.contains("100 managed device"))
        XCTAssertTrue(html.contains("95.0%"))  // fileVault
        XCTAssertTrue(html.contains("1 device") || html.contains("require"))
    }

    func testExecSummaryEmptyState() {
        let report = makeReport()
        let html = report.buildExecSummary(
            totalDevices: 0, fileVaultPct: 0, sipPct: 0, firewallPct: 0,
            deviceCompliance: [], patchStatus: []
        )
        XCTAssertTrue(html.contains("exec-summary"))
        XCTAssertTrue(html.contains("class=\"empty\"") || html.contains("could not be determined"))
    }

    func testExecSummaryXSS() {
        let report = makeReport()
        let html = report.buildExecSummary(
            totalDevices: 0, fileVaultPct: 0, sipPct: 0, firewallPct: 0,
            deviceCompliance: [], patchStatus: []
        )
        XCTAssertFalse(html.contains("<script>"))
    }

    func testExecSummaryStableOutput() {
        let report = makeReport()
        let compliance: [[String: Any]] = [["failure_count": 0]]
        let patch: [[String: Any]] = [["title": "T", "compliance_pct": "90%"]]
        let a = report.buildExecSummary(
            totalDevices: 50, fileVaultPct: 80, sipPct: 90, firewallPct: 70,
            deviceCompliance: compliance, patchStatus: patch
        )
        let b = report.buildExecSummary(
            totalDevices: 50, fileVaultPct: 80, sipPct: 90, firewallPct: 70,
            deviceCompliance: compliance, patchStatus: patch
        )
        XCTAssertEqual(a, b)
    }

    // MARK: - recentFailures

    func testRecentFailuresWithData() {
        let report = makeReport()
        let patch: [[String: Any]] = [
            ["device": "Mac-001", "serial": "ABC123", "policy": "Firefox 130",
             "status_date": "2026-04-15"],
        ]
        let html = report.buildRecentFailures(patchFailures: patch, updateFailures: [])
        XCTAssertTrue(html.contains("recent-failures"))
        XCTAssertTrue(html.contains("<table"))
        XCTAssertTrue(html.contains("Mac-001"))
        XCTAssertTrue(html.contains("Patch"))
    }

    func testRecentFailuresEmptyState() {
        let report = makeReport()
        let html = report.buildRecentFailures(patchFailures: [], updateFailures: [])
        XCTAssertTrue(html.contains("class=\"empty\""))
    }

    func testRecentFailuresXSS() {
        let report = makeReport()
        let patch: [[String: Any]] = [
            ["device": Self.xssPayload, "serial": "", "policy": "Firefox",
             "status_date": "2026-04-15"],
        ]
        let html = report.buildRecentFailures(patchFailures: patch, updateFailures: [])
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    func testRecentFailuresStableOutput() {
        let report = makeReport()
        let patch: [[String: Any]] = [
            ["device": "Mac-A", "serial": "X1", "policy": "Zoom", "status_date": "2026-03-01"],
        ]
        XCTAssertEqual(
            report.buildRecentFailures(patchFailures: patch, updateFailures: []),
            report.buildRecentFailures(patchFailures: patch, updateFailures: [])
        )
    }

    // MARK: - interventionList

    func testInterventionListWithData() {
        let report = makeReport()
        // Use a very old date so device is definitely stale (default threshold is 30 days)
        let inventory: [[String: Any]] = [
            ["name": "Stale-Mac", "serial_number": "S001",
             "last_check_in": "2020-01-01", "username": "jdoe"],
        ]
        let html = report.buildInterventionList(computersInventory: inventory)
        XCTAssertTrue(html.contains("intervention-list"))
        XCTAssertTrue(html.contains("<table"))
        XCTAssertTrue(html.contains("Stale-Mac"))
    }

    func testInterventionListEmptyState() {
        let report = makeReport()
        let html = report.buildInterventionList(computersInventory: [])
        XCTAssertTrue(html.contains("class=\"empty\""))
    }

    func testInterventionListXSS() {
        let report = makeReport()
        let inventory: [[String: Any]] = [
            ["name": Self.xssPayload, "serial_number": "",
             "last_check_in": "2020-01-01", "username": ""],
        ]
        let html = report.buildInterventionList(computersInventory: inventory)
        XCTAssertFalse(html.contains("<script>"))
    }

    // MARK: - patchQueue

    func testPatchQueueWithData() {
        let report = makeReport()
        let patch: [[String: Any]] = [
            ["title": "Firefox", "latest": "130.0", "on_other": 15,
             "total": 100, "compliance_pct": "85%"],
            ["title": "Zoom", "latest": "6.0", "on_other": 0, "total": 50,
             "compliance_pct": "100%"],
        ]
        let html = report.buildPatchQueue(patchStatus: patch)
        XCTAssertTrue(html.contains("patch-queue"))
        XCTAssertTrue(html.contains("<table"))
        XCTAssertTrue(html.contains("Firefox"))
        // Zoom has 0 pending — should not appear
        XCTAssertFalse(html.contains("Zoom"))
    }

    func testPatchQueueEmptyState() {
        let report = makeReport()
        let html = report.buildPatchQueue(patchStatus: [])
        XCTAssertTrue(html.contains("class=\"empty\""))
    }

    func testPatchQueueXSS() {
        let report = makeReport()
        let patch: [[String: Any]] = [
            ["title": Self.xssPayload, "latest": "1.0", "on_other": 5,
             "total": 10, "compliance_pct": "50%"],
        ]
        let html = report.buildPatchQueue(patchStatus: patch)
        XCTAssertFalse(html.contains("<script>"))
    }

    func testPatchQueueStableOutput() {
        let report = makeReport()
        let patch: [[String: Any]] = [
            ["title": "T", "latest": "1", "on_other": 3, "total": 10, "compliance_pct": "70%"],
        ]
        XCTAssertEqual(
            report.buildPatchQueue(patchStatus: patch),
            report.buildPatchQueue(patchStatus: patch)
        )
    }

    // MARK: - auditEvidence

    func testAuditEvidenceWithData() {
        let report = makeReport()
        let findings: [[String: Any]] = [
            ["severity": "high", "check": "filevault", "policy": "Security",
             "detail": "FileVault not enabled"],
            ["severity": "medium", "check": "sip", "policy": "Config",
             "detail": "SIP disabled"],
        ]
        let html = report.buildAuditEvidence(auditFindings: findings)
        XCTAssertTrue(html.contains("audit-evidence"))
        XCTAssertTrue(html.contains("<table"))
        XCTAssertTrue(html.contains("filevault"))
        XCTAssertTrue(html.contains("sev-high"))
    }

    func testAuditEvidenceEmptyState() {
        let report = makeReport()
        let html = report.buildAuditEvidence(auditFindings: [])
        XCTAssertTrue(html.contains("class=\"empty\""))
    }

    func testAuditEvidenceXSS() {
        let report = makeReport()
        let findings: [[String: Any]] = [
            ["severity": "high", "check": Self.xssPayload, "policy": "", "detail": ""],
        ]
        let html = report.buildAuditEvidence(auditFindings: findings)
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    func testAuditEvidenceStableOutput() {
        let report = makeReport()
        let findings: [[String: Any]] = [
            ["severity": "high", "check": "A", "policy": "B", "detail": "C"],
        ]
        XCTAssertEqual(
            report.buildAuditEvidence(auditFindings: findings),
            report.buildAuditEvidence(auditFindings: findings)
        )
    }

    // MARK: - exceptionList

    func testExceptionListWithData() throws {
        let yaml = """
        custom_eas:
          - name: "FileVault Status"
            column: "FileVault 2 - Status"
            type: boolean
            true_value: "Encrypted"
        """
        let config = try ConfigLoader.loadFromString(yaml)
        let report = makeReport(config: config)
        let html = report.buildExceptionList()
        XCTAssertTrue(html.contains("exception-list"))
        XCTAssertTrue(html.contains("<table"))
        XCTAssertTrue(html.contains("FileVault Status"))
    }

    func testExceptionListEmptyState() {
        let report = makeReport()
        let html = report.buildExceptionList()
        XCTAssertTrue(html.contains("class=\"empty\""))
    }

    func testExceptionListXSS() throws {
        let yaml = """
        custom_eas:
          - name: "<script>x</script>"
            column: "Col"
            type: text
        """
        let config = try ConfigLoader.loadFromString(yaml)
        let report = makeReport(config: config)
        let html = report.buildExceptionList()
        XCTAssertFalse(html.contains("<script>"))
    }

    // MARK: - assetMap

    func testAssetMapWithData() {
        let report = makeReport()
        let inventory: [[String: Any]] = [
            ["name": "Mac-001", "serial_number": "X001", "asset_tag": "IT-001",
             "department": "Engineering", "building": "HQ"],
        ]
        let html = report.buildAssetMap(computersInventory: inventory)
        XCTAssertTrue(html.contains("asset-map"))
        XCTAssertTrue(html.contains("<table"))
        XCTAssertTrue(html.contains("Mac-001"))
        XCTAssertTrue(html.contains("IT-001"))
    }

    func testAssetMapEmptyState() {
        let report = makeReport()
        let html = report.buildAssetMap(computersInventory: [])
        XCTAssertTrue(html.contains("class=\"empty\""))
    }

    func testAssetMapXSS() {
        let report = makeReport()
        let inventory: [[String: Any]] = [
            ["name": Self.xssPayload, "serial_number": "", "asset_tag": "",
             "department": "", "building": ""],
        ]
        let html = report.buildAssetMap(computersInventory: inventory)
        XCTAssertFalse(html.contains("<script>"))
    }

    func testAssetMapStableOutput() {
        let report = makeReport()
        let inv: [[String: Any]] = [
            ["name": "M1", "serial_number": "S1", "asset_tag": "A1",
             "department": "D", "building": "B"],
        ]
        XCTAssertEqual(
            report.buildAssetMap(computersInventory: inv),
            report.buildAssetMap(computersInventory: inv)
        )
    }

    // MARK: - purchaseCohorts

    func testPurchaseCohortsWithData() {
        let report = makeReport()
        let inventory: [[String: Any]] = [
            ["name": "Mac-A", "purchase_date": "2022-06-01"],
            ["name": "Mac-B", "purchase_date": "2022-11-15"],
            ["name": "Mac-C", "purchase_date": "2023-02-01"],
        ]
        let html = report.buildPurchaseCohorts(computersInventory: inventory)
        XCTAssertTrue(html.contains("purchase-cohorts"))
        XCTAssertTrue(html.contains("<table"))
        XCTAssertTrue(html.contains("2022"))
        XCTAssertTrue(html.contains("2023"))
    }

    func testPurchaseCohortsEmptyState() {
        let report = makeReport()
        let html = report.buildPurchaseCohorts(computersInventory: [])
        XCTAssertTrue(html.contains("class=\"empty\""))
    }

    func testPurchaseCohortsNoPurchaseDateEmptyState() {
        let report = makeReport()
        let inventory: [[String: Any]] = [["name": "Mac"]]
        let html = report.buildPurchaseCohorts(computersInventory: inventory)
        XCTAssertTrue(html.contains("class=\"empty\""))
    }

    func testPurchaseCohortsXSS() {
        let report = makeReport()
        let inventory: [[String: Any]] = [
            ["name": Self.xssPayload, "purchase_date": "2024-01-01"],
        ]
        let html = report.buildPurchaseCohorts(computersInventory: inventory)
        XCTAssertFalse(html.contains("<script>"))
    }

    // MARK: - buildingBreakdown

    func testBuildingBreakdownWithData() {
        let report = makeReport()
        let inventory: [[String: Any]] = [
            ["name": "M1", "building": "HQ"],
            ["name": "M2", "building": "HQ"],
            ["name": "M3", "building": "Remote"],
        ]
        let html = report.buildBuildingBreakdown(computersInventory: inventory)
        XCTAssertTrue(html.contains("building-breakdown"))
        XCTAssertTrue(html.contains("<table"))
        XCTAssertTrue(html.contains("HQ"))
        XCTAssertTrue(html.contains("Remote"))
    }

    func testBuildingBreakdownEmptyState() {
        let report = makeReport()
        let html = report.buildBuildingBreakdown(computersInventory: [])
        XCTAssertTrue(html.contains("class=\"empty\""))
    }

    func testBuildingBreakdownXSS() {
        let report = makeReport()
        let inventory: [[String: Any]] = [
            ["name": "M1", "building": Self.xssPayload],
        ]
        let html = report.buildBuildingBreakdown(computersInventory: inventory)
        XCTAssertFalse(html.contains("<script>"))
    }

    func testBuildingBreakdownStableOutput() {
        let report = makeReport()
        let inv: [[String: Any]] = [["name": "M", "building": "B"]]
        XCTAssertEqual(
            report.buildBuildingBreakdown(computersInventory: inv),
            report.buildBuildingBreakdown(computersInventory: inv)
        )
    }

    // MARK: - departmentBreakdown

    func testDepartmentBreakdownWithData() {
        let report = makeReport()
        let inventory: [[String: Any]] = [
            ["name": "M1", "department": "Engineering"],
            ["name": "M2", "department": "Engineering"],
            ["name": "M3", "department": "Finance"],
        ]
        let html = report.buildDepartmentBreakdown(computersInventory: inventory)
        XCTAssertTrue(html.contains("department-breakdown"))
        XCTAssertTrue(html.contains("<table"))
        XCTAssertTrue(html.contains("Engineering"))
        XCTAssertTrue(html.contains("Finance"))
    }

    func testDepartmentBreakdownEmptyState() {
        let report = makeReport()
        let html = report.buildDepartmentBreakdown(computersInventory: [])
        XCTAssertTrue(html.contains("class=\"empty\""))
    }

    func testDepartmentBreakdownXSS() {
        let report = makeReport()
        let inventory: [[String: Any]] = [
            ["name": "M1", "department": Self.xssPayload],
        ]
        let html = report.buildDepartmentBreakdown(computersInventory: inventory)
        XCTAssertFalse(html.contains("<script>"))
    }

    // MARK: - protectAlerts

    func testProtectAlertsNoProtectConfig() {
        let report = makeReport()
        let html = report.buildProtectAlerts(protectDataDir: nil)
        XCTAssertTrue(html.contains("protect-alerts"))
        XCTAssertTrue(html.contains("class=\"empty\""))
    }

    func testProtectAlertsEmptyCache() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProtectAlertTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let report = makeReport()
        let html = report.buildProtectAlerts(protectDataDir: tmp)
        XCTAssertTrue(html.contains("class=\"empty\""))
        XCTAssertFalse(html.contains("jamf-cli protect collect"),
            "the empty state must not name a command jamf-cli does not have")
    }

    /// Jamf Protect's severity enum is High, Medium, Low, Informational — there
    /// is no Critical. Informational must be styled as a real severity and
    /// ordered last, not dropped into the unknown bucket at the end.
    func testProtectAlertsOrdersAndStylesProtectSeverities() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProtectAlertsSeverity-\(UUID().uuidString)", isDirectory: true)
        let alertsDir = tmp.appendingPathComponent("protect-alerts", isDirectory: true)
        try FileManager.default.createDirectory(at: alertsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let alerts: [[String: Any]] = [
            ["severity": "Informational", "eventType": "GPFSEvent", "computer": "Mac-Info",
             "created": "2026-04-01T00:00:00Z"],
            ["severity": "Low", "eventType": "GPClickEvent", "computer": "Mac-Low",
             "created": "2026-04-01T00:00:00Z"],
            ["severity": "High", "eventType": "GPProcessEvent", "computer": "Mac-High",
             "created": "2026-04-01T00:00:00Z"],
        ]
        try JSONSerialization.data(withJSONObject: alerts)
            .write(to: alertsDir.appendingPathComponent("protect-alerts_20260401T000000.json"))

        let html = makeReport().buildProtectAlerts(protectDataDir: tmp)

        XCTAssertTrue(html.contains("sev-pill sev-info\">informational"),
            "Informational is a Protect severity, not an unknown one")
        let high = try XCTUnwrap(html.range(of: "Mac-High"))
        let low = try XCTUnwrap(html.range(of: "Mac-Low"))
        let info = try XCTUnwrap(html.range(of: "Mac-Info"))
        XCTAssertLessThan(high.lowerBound, low.lowerBound, "High leads")
        XCTAssertLessThan(low.lowerBound, info.lowerBound, "Informational is last of the four")
    }

    func testProtectAlertsStableOutput() {
        let report = makeReport()
        let a = report.buildProtectAlerts(protectDataDir: nil)
        let b = report.buildProtectAlerts(protectDataDir: nil)
        XCTAssertEqual(a, b)
    }

    /// jamf-cli's real flattened alert row shape (v1.29.0): `computer` is the
    /// host name string, `eventType` names the alert, `analytics` is a
    /// comma-joined fallback list, and `computer` is absent (not empty) when
    /// the alert has no associated device.
    func testProtectAlertsRendersRealJamfCLIShape() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProtectAlertsShape-\(UUID().uuidString)", isDirectory: true)
        let alertsDir = tmp.appendingPathComponent("protect-alerts", isDirectory: true)
        try FileManager.default.createDirectory(at: alertsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let alerts: [[String: Any]] = [
            ["uuid": "a1", "status": "New", "severity": "High",
             "eventType": "Malware Detected", "computer": "Mac-Dev-01",
             "received": "2026-04-01T00:00:00Z", "created": "2026-04-01T12:00:00Z"],
            ["uuid": "a2", "status": "New", "severity": "High",
             "eventType": "", "analytics": "Suspicious Script, Persistence",
             "created": "2026-04-02T08:00:00Z"],
        ]
        let data = try JSONSerialization.data(withJSONObject: alerts)
        try data.write(to: alertsDir.appendingPathComponent("protect-alerts_20260402T000000.json"))

        let report = makeReport()
        let html = report.buildProtectAlerts(protectDataDir: tmp)

        XCTAssertTrue(html.contains("Mac-Dev-01"), "Should render the computer host name")
        XCTAssertTrue(html.contains("Malware Detected"), "Should render eventType as the alert")
        XCTAssertTrue(html.contains("2026-04-01"), "Date should be the first 10 chars of created")
        XCTAssertTrue(html.contains("Suspicious Script, Persistence"),
            "Should fall back to analytics when eventType is empty")
        XCTAssertTrue(html.contains("<td>—</td><td>Suspicious Script, Persistence</td>"),
            "An alert with no computer must still render its row")
    }

    // MARK: - insightsDrift

    func testInsightsDriftNoProtectConfig() {
        let report = makeReport()
        let html = report.buildInsightsDrift(protectDataDir: nil)
        XCTAssertTrue(html.contains("insights-drift"))
        XCTAssertTrue(html.contains("class=\"empty\""))
    }

    func testInsightsDriftInsufficientSnapshots() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("InsightsDriftTest-\(UUID().uuidString)", isDirectory: true)
        let insightsDir = tmp.appendingPathComponent("protect-insights", isDirectory: true)
        try FileManager.default.createDirectory(at: insightsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Write exactly one snapshot — jamf-cli's array-of-rows shape.
        let snap: [[String: Any]] = [
            ["label": "FileVault Enabled", "section": "Encryption", "enabled": true,
             "totalPass": 97, "totalFail": 3, "totalNone": 0],
        ]
        let data = try JSONSerialization.data(withJSONObject: snap)
        let name = "protect-insights_20260101T000000.json"
        try data.write(to: insightsDir.appendingPathComponent(name))

        let report = makeReport()
        let html = report.buildInsightsDrift(protectDataDir: tmp)
        XCTAssertTrue(html.contains("class=\"empty\""))
        XCTAssertTrue(html.contains("N≥2") || html.contains("snapshot"))
    }

    func testInsightsDriftWithTwoSnapshots() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("InsightsDriftTest2-\(UUID().uuidString)", isDirectory: true)
        let insightsDir = tmp.appendingPathComponent("protect-insights", isDirectory: true)
        try FileManager.default.createDirectory(at: insightsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let snap1: [[String: Any]] = [
            ["label": "FileVault Enabled", "section": "Encryption", "enabled": true,
             "totalPass": 90, "totalFail": 10, "totalNone": 0],
        ]
        let snap2: [[String: Any]] = [
            ["label": "FileVault Enabled", "section": "Encryption", "enabled": true,
             "totalPass": 99, "totalFail": 1, "totalNone": 0],
        ]
        let d1 = try JSONSerialization.data(withJSONObject: snap1)
        let d2 = try JSONSerialization.data(withJSONObject: snap2)
        // Canonical stamped filenames order deterministically — no mtime needed.
        let url1 = insightsDir.appendingPathComponent("protect-insights_20260101T000000.json")
        let url2 = insightsDir.appendingPathComponent("protect-insights_20260201T000000.json")
        try d1.write(to: url1)
        try d2.write(to: url2)

        let report = makeReport()
        let html = report.buildInsightsDrift(protectDataDir: tmp)
        XCTAssertTrue(html.contains("insights-drift"))
        XCTAssertTrue(html.contains("<table"))
        XCTAssertTrue(html.contains("FileVault Enabled"))
    }

    /// jamf-cli's real insights row shape is a bare ARRAY of {label, section,
    /// enabled, totalPass, totalFail, totalNone, cisIDs} objects, not a single
    /// dict — the drift table must reduce each day to failing-device counts
    /// per insight label, and say plainly what the numbers mean.
    func testInsightsDriftRendersFailingDeviceCountsFromRealShape() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("InsightsDriftShape-\(UUID().uuidString)", isDirectory: true)
        let insightsDir = tmp.appendingPathComponent("protect-insights", isDirectory: true)
        try FileManager.default.createDirectory(at: insightsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let day1: [[String: Any]] = [
            ["label": "Unsigned Kernel Extension", "section": "Kernel", "enabled": true,
             "totalPass": 90, "totalFail": 10, "totalNone": 0, "cisIDs": ""],
        ]
        let day2: [[String: Any]] = [
            ["label": "Unsigned Kernel Extension", "section": "Kernel", "enabled": true,
             "totalPass": 97, "totalFail": 3, "totalNone": 0, "cisIDs": ""],
        ]
        let url1 = insightsDir.appendingPathComponent("protect-insights_20260401T000000.json")
        let url2 = insightsDir.appendingPathComponent("protect-insights_20260402T000000.json")
        try JSONSerialization.data(withJSONObject: day1).write(to: url1)
        try JSONSerialization.data(withJSONObject: day2).write(to: url2)

        let report = makeReport()
        let html = report.buildInsightsDrift(protectDataDir: tmp)

        XCTAssertTrue(html.contains("Unsigned Kernel Extension"))
        XCTAssertTrue(html.contains("failing-device counts"),
            "Table must say plainly that the numbers are failing-device counts")
        XCTAssertTrue(html.contains(">10<"), "Previous day's totalFail (10) must render")
        XCTAssertTrue(html.contains(">3<"), "Current day's totalFail (3) must render")
    }

    // MARK: - agentHealth

    func testAgentHealthNoAgentsConfigured() {
        let report = makeReport()
        let html = report.buildAgentHealth(computersInventory: [])
        XCTAssertTrue(html.contains("agent-health"))
        XCTAssertTrue(html.contains("class=\"empty\""))
    }

    func testAgentHealthWithData() throws {
        let yaml = """
        security_agents:
          - name: "CrowdStrike Falcon"
            column: "CrowdStrike Falcon - Status"
            connected_value: "Installed"
        """
        let config = try ConfigLoader.loadFromString(yaml)
        let report = makeReport(config: config)
        let inventory: [[String: Any]] = [
            ["name": "Mac-A", "CrowdStrike Falcon - Status": "Installed"],
            ["name": "Mac-B", "CrowdStrike Falcon - Status": "Not Installed"],
            ["name": "Mac-C"],
        ]
        let html = report.buildAgentHealth(computersInventory: inventory)
        XCTAssertTrue(html.contains("agent-health"))
        XCTAssertTrue(html.contains("<table"))
        XCTAssertTrue(html.contains("CrowdStrike Falcon"))
        XCTAssertTrue(html.contains("count-card"))
    }

    func testAgentHealthEmptyInventory() throws {
        let yaml = """
        security_agents:
          - name: "Falcon"
            column: "Falcon Status"
            connected_value: "Up"
        """
        let config = try ConfigLoader.loadFromString(yaml)
        let report = makeReport(config: config)
        let html = report.buildAgentHealth(computersInventory: [])
        XCTAssertTrue(html.contains("class=\"empty\""))
    }

    func testAgentHealthXSS() throws {
        let yaml = """
        security_agents:
          - name: "Agent"
            column: "Status"
            connected_value: "Up"
        """
        let config = try ConfigLoader.loadFromString(yaml)
        let report = makeReport(config: config)
        let inventory: [[String: Any]] = [
            ["name": Self.xssPayload, "Status": "Up"],
        ]
        let html = report.buildAgentHealth(computersInventory: inventory)
        XCTAssertFalse(html.contains("<script>"))
    }

    func testAgentHealthStableOutput() throws {
        let yaml = """
        security_agents:
          - name: "Falcon"
            column: "S"
            connected_value: "Up"
        """
        let config = try ConfigLoader.loadFromString(yaml)
        let report = makeReport(config: config)
        let inv: [[String: Any]] = [["name": "M", "S": "Up"]]
        XCTAssertEqual(
            report.buildAgentHealth(computersInventory: inv),
            report.buildAgentHealth(computersInventory: inv)
        )
    }

}
