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

    /// A reverse-DNS name wraps at its separators, and nothing is added where no text follows.
    func testEscapeHTMLBreakableBreaksAfterSeparatorsOnly() {
        let breakable = HtmlSectionFormatters.escapeHTMLBreakable
        XCTAssertEqual(
            breakable("org.example_800.audit.plist"),
            "org.<wbr>example_<wbr>800.<wbr>audit.<wbr>plist")
        XCTAssertEqual(breakable("a/b."), "a/<wbr>b.")
        XCTAssertEqual(breakable("Compliance Benchmark"), "Compliance Benchmark")
        XCTAssertEqual(breakable("v1.2 <b>"), "v1.<wbr>2 &lt;b&gt;")
    }

    func testEscapeHTMLBreakableStillEscapes() {
        let html = HtmlSectionFormatters.escapeHTMLBreakable(Self.xssPayload)
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;/<wbr>script&gt;"))
    }

    func testAINarrativeSectionIsASpacedBlockWithItsCaptionInAClass() {
        let html = makeReport().buildAINarrativeSection("Fleet <b>ok</b> & stable")
        XCTAssertTrue(html.contains("<section class=\"summary-block\" id=\"ai-narrative\">"))
        XCTAssertTrue(html.contains("<p class=\"ai-note\">"))
        XCTAssertFalse(html.contains("style="), "the caption's look lives in the style sheet")
        XCTAssertTrue(html.contains("Fleet &lt;b&gt;ok&lt;/b&gt; &amp; stable"))
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

    /// Percent bars share one 0–100 track, so equal shares draw equal bars; a share outside
    /// the track, or not a number, is held to it.
    func testRenderPercentBarsUseOneTrackAndHoldOddValuesToIt() {
        let html = HtmlSectionFormatters.renderPercentBars([
            (label: "A", pct: 40), (label: "B", pct: 40), (label: "C", pct: 83.4),
            (label: "D", pct: 140), (label: "E", pct: -3), (label: "F", pct: .nan),
        ])
        XCTAssertEqual(html.components(separatedBy: "width:40%").count - 1, 2)
        XCTAssertTrue(html.contains("C: 83.4%"))
        XCTAssertTrue(html.contains("width:83%"))
        XCTAssertTrue(html.contains("D: 100%") && html.contains("width:100%"))
        XCTAssertTrue(html.contains("E: 0%") && html.contains("F: 0%"))
        XCTAssertFalse(html.contains("width:-"))
    }

    /// Count bars scale to the largest row and name the unit.
    func testRenderBarsScaleToTheLargestRow() {
        let html = HtmlSectionFormatters.renderBars(
            [(label: "x", count: 8), (label: "y", count: 2)])
        XCTAssertTrue(html.contains("width:100%"))
        XCTAssertTrue(html.contains("width:25%"))
        XCTAssertTrue(html.contains("y: 2 devices"))
        XCTAssertTrue(HtmlSectionFormatters.renderBars([(label: "z", count: 1)])
            .contains("z: 1 device\""))
    }

    // MARK: - Fleet counts fixture

    /// Counts as the summary tiles read them: 100 Macs, FileVault off on 5, Firewall off on 12.
    private func fleet(
        fileVaultFail: Int = 5, firewallFail: Int = 12, unreported: Int = 0
    ) -> SecurityFleetCounts {
        func control(_ fail: Int, notReported: Int = 0) -> SecurityFleetCounts.Control {
            .init(level: .fail, on: 100 - fail - notReported, fail: fail, warning: 0,
                  notReported: notReported)
        }
        return SecurityFleetCounts(
            totalDevices: 100,
            controls: [.fileVault: control(fileVaultFail),
                       .sip: control(0, notReported: unreported),
                       .firewall: control(firewallFail), .gatekeeper: control(0)],
            fileVaultOffHardwareEncrypted: 0)
    }

    // MARK: - securityGapSentence

    func testSecurityGapSentenceNamesNoGapWhenNoMacFails() {
        let sentence = HtmlReport.securityGapSentence(fleet(fileVaultFail: 0, firewallFail: 0))
        XCTAssertEqual(sentence, "No Mac has a gap in FileVault, SIP, Firewall, Gatekeeper.")
    }

    func testSecurityGapSentenceUsesTheSingularForOneMac() {
        let sentence = HtmlReport.securityGapSentence(fleet(fileVaultFail: 1, firewallFail: 0))
        XCTAssertEqual(sentence, "Security gaps to remediate: FileVault off on 1 Mac.")
    }

    func testSecurityGapSentenceSaysWhatJamfDidNotReport() {
        let sentence = HtmlReport.securityGapSentence(fleet(unreported: 3))
        XCTAssertTrue(sentence.hasSuffix(
            " 3 control values were not reported by Jamf and not counted as gaps."), sentence)
    }

    func testSecurityGapSentenceSkipsAnIgnoredControl() {
        let ignored = SecurityFleetCounts(
            totalDevices: 100,
            controls: [.fileVault: .init(level: .fail, on: 100, fail: 0, warning: 0),
                       .firewall: .init(level: .ignore, on: 50, fail: 50, warning: 0)],
            fileVaultOffHardwareEncrypted: 0)
        XCTAssertEqual(HtmlReport.securityGapSentence(ignored),
                       "No Mac has a gap in FileVault.")
    }

    func testSecurityGapSentenceWithoutACountMakesNoClaim() {
        XCTAssertEqual(HtmlReport.securityGapSentence(nil),
                       "No security control counts are available in the current snapshot.")
        XCTAssertEqual(HtmlReport.securityGapSentence(.empty),
                       "No security control counts are available in the current snapshot.")
    }

    // MARK: - recentFailures

    func testRecentFailuresWithData() {
        let report = makeReport()
        let patch: [[String: Any]] = [
            ["device": "Mac-001", "serial": "ABC123", "policy": "Firefox 130",
             "status_date": "2026-04-15"],
        ]
        let html = report.buildRecentFailures(patchFailures: patch, updateFailures: []).html
        XCTAssertTrue(html.contains("recent-failures"))
        XCTAssertTrue(html.contains("<table"))
        XCTAssertTrue(html.contains("Mac-001"))
        XCTAssertTrue(html.contains("Patch"))
    }

    /// The update snapshot is one envelope, not a list of failures; reading the envelope
    /// as a row printed an empty "Update" line and none of the failed plans.
    func testUpdateFailureRowsFlattenTheEnvelope() {
        let envelope: [[String: Any]] = [[
            "total": 10,
            "error_devices": NSNull(),
            "failed_plans": [
                ["name": "Mac-1", "serial": "S1", "version": "LATEST_MINOR"],
                ["name": "Mac-2", "serial": "S2", "version": "LATEST_MAJOR"],
            ],
        ]]
        let rows = HtmlReport.updateFailureRows(from: envelope)
        XCTAssertEqual(rows.compactMap { $0["name"] as? String }, ["Mac-1", "Mac-2"])

        let html = makeReport().buildRecentFailures(patchFailures: [], updateFailures: rows).html
        XCTAssertTrue(html.contains("Mac-1"))
        XCTAssertTrue(html.contains("LATEST_MAJOR"))
    }

    func testUpdateFailureRowsKeepAnEnvelopeWithBothListsNullEmpty() {
        let envelope: [[String: Any]] = [["error_devices": NSNull(), "failed_plans": NSNull()]]
        XCTAssertTrue(HtmlReport.updateFailureRows(from: envelope).isEmpty)
    }

    func testUpdateFailureRowsPassThroughAFlatRow() {
        let flat: [[String: Any]] = [["name": "Mac-1", "version": "26.1"]]
        XCTAssertEqual(HtmlReport.updateFailureRows(from: flat).count, 1)
    }

    /// A row with no readable date must not outrank a dated one: 300 undated update
    /// plans would otherwise fill the 25 slots ahead of every dated patch failure.
    func testRecentFailuresSortsUndatedRowsAfterDatedOnes() {
        let patch: [[String: Any]] = [
            ["device": "Dated-Patch-Mac", "serial": "P1", "policy": "Zoom",
             "status_date": "2026-03-01"],
        ]
        let update: [[String: Any]] = (0..<30).map {
            ["name": "Undated-Mac-\($0)", "serial": "U\($0)", "version": "LATEST_MINOR",
             "last_event": "PlanFailed"]
        }
        let html = makeReport().buildRecentFailures(
            patchFailures: patch, updateFailures: update).html
        let dated = html.range(of: "Dated-Patch-Mac")
        XCTAssertNotNil(dated)
        XCTAssertTrue(html.contains("Undated-Mac-0"))
        let firstUndated = html.range(of: "Undated-Mac-0")
        if let dated, let firstUndated {
            XCTAssertLessThan(dated.lowerBound, firstUndated.lowerBound)
        }
    }

    func testRecentFailuresAreLeftOutWhenThereAreNone() {
        let block = makeReport().buildRecentFailures(patchFailures: [], updateFailures: [])
        XCTAssertTrue(block.html.isEmpty)
        XCTAssertEqual(block.omission, "no patch or update failures in the snapshots")
    }

    /// Thirty failures: ten rows show, the other twenty sit behind "Show all 30".
    func testRecentFailuresShowTenAndKeepTheRestBehindShowAll() {
        let patch: [[String: Any]] = (0..<30).map {
            ["device": "Mac-\($0)", "serial": "S\($0)", "policy": "Zoom",
             "status_date": "2026-03-\(String(format: "%02d", $0 % 28 + 1))"]
        }
        let html = makeReport().buildRecentFailures(patchFailures: patch, updateFailures: []).html
        let (shown, rest) = Self.splitAtShowAll(html)
        XCTAssertEqual(Self.bodyRows(shown), 10)
        XCTAssertTrue(html.contains("<summary>Show all 30</summary>"))
        XCTAssertEqual(Self.bodyRows(rest), 20)
    }

    /// Body rows in `html`: every row `renderTable` closes after its last cell.
    static func bodyRows(_ html: String) -> Int {
        html.components(separatedBy: "</td></tr>").count - 1
    }

    /// The markup before and after the "Show all" disclosure.
    static func splitAtShowAll(_ html: String) -> (shown: String, rest: String) {
        guard let range = html.range(of: "<details class=\"show-all\"") else { return (html, "") }
        return (String(html[..<range.lowerBound]), String(html[range.lowerBound...]))
    }

    func testRecentFailuresXSS() {
        let report = makeReport()
        let patch: [[String: Any]] = [
            ["device": Self.xssPayload, "serial": "", "policy": "Firefox",
             "status_date": "2026-04-15"],
        ]
        let html = report.buildRecentFailures(patchFailures: patch, updateFailures: []).html
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    func testRecentFailuresStableOutput() {
        let report = makeReport()
        let patch: [[String: Any]] = [
            ["device": "Mac-A", "serial": "X1", "policy": "Zoom", "status_date": "2026-03-01"],
        ]
        XCTAssertEqual(
            report.buildRecentFailures(patchFailures: patch, updateFailures: []).html,
            report.buildRecentFailures(patchFailures: patch, updateFailures: []).html
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
        let html = report.buildInterventionList(computersInventory: inventory).html
        XCTAssertTrue(html.contains("intervention-list"))
        XCTAssertTrue(html.contains("<table"))
        XCTAssertTrue(html.contains("Stale-Mac"))
        XCTAssertTrue(html.contains("Macs with no check-in for more than 30 days (1)"), html)
    }

    func testInterventionListIsLeftOutWithoutAComputersSnapshot() {
        let block = makeReport().buildInterventionList(computersInventory: [])
        XCTAssertTrue(block.html.isEmpty)
        XCTAssertEqual(block.omission, "no computers snapshot")
    }

    /// "More than N days": a Mac at exactly the threshold is not listed, one day later is.
    func testInterventionListHoldsMacsPastTheThresholdNotAtIt() {
        func stamp(daysAgo: Int) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
            return formatter.string(
                from: Date().addingTimeInterval(-Double(daysAgo) * 86_400 - 3_600))
        }
        let report = makeReport()
        let inventory: [[String: Any]] = [
            ["name": "Mac-at-30", "serial_number": "S30", "last_check_in": stamp(daysAgo: 30)],
            ["name": "Mac-at-31", "serial_number": "S31", "last_check_in": stamp(daysAgo: 31)],
        ]
        XCTAssertEqual(report.staleComputers(inventory).map(\.age), [.days(31)])
        let html = report.buildInterventionList(computersInventory: inventory).html
        XCTAssertTrue(html.contains("Mac-at-31"))
        XCTAssertFalse(html.contains("Mac-at-30"))
    }

    func testInterventionListIsLeftOutWhenNoMacIsPastTheThreshold() {
        let recent: [[String: Any]] = [["name": "Fresh", "last_check_in": "2999-01-01"]]
        let block = makeReport().buildInterventionList(computersInventory: recent)
        XCTAssertTrue(block.html.isEmpty)
        XCTAssertEqual(block.omission, "no Mac has gone more than 30 days without a check-in")
    }

    /// A hundred and five stale Macs: ten show, the other ninety-five sit behind "Show all".
    func testInterventionListKeepsEveryRowBehindShowAll() {
        let inventory: [[String: Any]] = (0..<105).map {
            ["name": "Stale-\($0)", "serial_number": "S\($0)", "last_check_in": "2020-01-01"]
        }
        let html = makeReport().buildInterventionList(computersInventory: inventory).html
        let (shown, rest) = Self.splitAtShowAll(html)
        XCTAssertEqual(Self.bodyRows(shown), 10)
        XCTAssertEqual(Self.bodyRows(rest), 95)
        XCTAssertTrue(html.contains("<summary>Show all 105</summary>"))
    }

    func testInterventionListXSS() {
        let report = makeReport()
        let inventory: [[String: Any]] = [
            ["name": Self.xssPayload, "serial_number": "",
             "last_check_in": "2020-01-01", "username": ""],
        ]
        let html = report.buildInterventionList(computersInventory: inventory).html
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
        let html = report.buildPatchQueue(patchStatus: patch).html
        XCTAssertTrue(html.contains("patch-queue"))
        XCTAssertTrue(html.contains("<table"))
        XCTAssertTrue(html.contains("Firefox"))
        // Zoom has 0 pending — should not appear
        XCTAssertFalse(html.contains("Zoom"))
    }

    func testPatchQueueIsLeftOutWithoutASnapshot() {
        let block = makeReport().buildPatchQueue(patchStatus: [])
        XCTAssertTrue(block.html.isEmpty)
        XCTAssertEqual(block.omission, "no patch-status snapshot")
    }

    func testPatchQueueIsLeftOutWhenEveryTitleIsCurrent() {
        let patch: [[String: Any]] = [["title": "Zoom", "on_other": 0, "total": 50]]
        let block = makeReport().buildPatchQueue(patchStatus: patch)
        XCTAssertTrue(block.html.isEmpty)
        XCTAssertEqual(block.omission, "every tracked patch title is on its latest version")
    }

    func testPatchQueueXSS() {
        let report = makeReport()
        let patch: [[String: Any]] = [
            ["title": Self.xssPayload, "latest": "1.0", "on_other": 5,
             "total": 10, "compliance_pct": "50%"],
        ]
        let html = report.buildPatchQueue(patchStatus: patch).html
        XCTAssertFalse(html.contains("<script>"))
    }

    func testPatchQueueStableOutput() {
        let report = makeReport()
        let patch: [[String: Any]] = [
            ["title": "T", "latest": "1", "on_other": 3, "total": 10, "compliance_pct": "70%"],
        ]
        XCTAssertEqual(
            report.buildPatchQueue(patchStatus: patch).html,
            report.buildPatchQueue(patchStatus: patch).html
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
        let html = report.buildAuditEvidence(auditFindings: findings).html
        XCTAssertTrue(html.contains("audit-evidence"))
        XCTAssertTrue(html.contains("<table"))
        XCTAssertTrue(html.contains("filevault"))
        XCTAssertTrue(html.contains("sev-high"))
    }

    /// `pro audit` writes `{name, category, severity, affected, recommendation}`; the section
    /// used to read other keys and print blank columns.
    func testAuditEvidenceReadsTheRowsProAuditWrites() {
        let findings: [[String: Any]] = [
            ["name": "Stale check-in (>14 days)", "category": "compliance", "severity": "WARNING",
             "affected": 101, "recommendation": "Investigate devices not checking in"],
        ]
        let html = makeReport().buildAuditEvidence(auditFindings: findings).html
        XCTAssertTrue(html.contains("<td>Stale check-in (&gt;14 days)</td>"), html)
        XCTAssertTrue(html.contains("<td>compliance</td>"))
        XCTAssertTrue(html.contains("<td>Investigate devices not checking in</td>"))
        XCTAssertTrue(html.contains("<th>Affected</th>"))
        XCTAssertTrue(html.contains("<td>101</td>"))
    }

    func testAuditEvidenceIsLeftOutWithoutFindings() {
        let block = makeReport().buildAuditEvidence(auditFindings: [])
        XCTAssertTrue(block.html.isEmpty)
        XCTAssertEqual(block.omission, "no audit findings in the snapshot")
    }

    func testAuditEvidenceXSS() {
        let report = makeReport()
        let findings: [[String: Any]] = [
            ["severity": "high", "check": Self.xssPayload, "policy": "", "detail": ""],
        ]
        let html = report.buildAuditEvidence(auditFindings: findings).html
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    func testAuditEvidenceStableOutput() {
        let report = makeReport()
        let findings: [[String: Any]] = [
            ["severity": "high", "check": "A", "policy": "B", "detail": "C"],
        ]
        XCTAssertEqual(
            report.buildAuditEvidence(auditFindings: findings).html,
            report.buildAuditEvidence(auditFindings: findings).html
        )
    }

    // MARK: - exceptionList

    func testExceptionListWithData() throws {
        let yaml = """
        exceptions:
          - id: "EX-001"
            description: "Waived for the lab fleet"
            signed_off_by: "A. Reviewer"
            signed_off_date: "2026-01-02"
        """
        let config = try ConfigLoader.loadFromString(yaml)
        let html = makeReport(config: config).buildExceptionList().html
        XCTAssertTrue(html.contains("exception-list"))
        XCTAssertTrue(html.contains("<table"))
        XCTAssertTrue(html.contains("EX-001"))
    }

    func testExceptionListIsLeftOutWhenNotConfigured() {
        let block = makeReport().buildExceptionList()
        XCTAssertTrue(block.html.isEmpty)
        XCTAssertEqual(block.omission, "not configured: no exceptions: block in config.yaml")
    }

    func testExceptionListXSS() throws {
        let yaml = """
        exceptions:
          - id: "<script>x</script>"
            description: "d"
            signed_off_by: "s"
            signed_off_date: "2026-01-02"
        """
        let config = try ConfigLoader.loadFromString(yaml)
        let html = makeReport(config: config).buildExceptionList().html
        XCTAssertFalse(html.contains("<script>"))
    }

    // MARK: - purchaseCohorts

    func testPurchaseCohortsWithData() {
        let report = makeReport()
        let inventory: [[String: Any]] = [
            ["name": "Mac-A", "purchase_date": "2022-06-01"],
            ["name": "Mac-B", "purchase_date": "2022-11-15"],
            ["name": "Mac-C", "purchase_date": "2023-02-01"],
        ]
        let html = report.buildPurchaseCohorts(computersInventory: inventory).html
        XCTAssertTrue(html.contains("purchase-cohorts"))
        XCTAssertTrue(html.contains("cohort-bar-row"))
        XCTAssertFalse(html.contains("<table"), "the bars carry the counts; no second table")
        XCTAssertTrue(html.contains("2022"))
        XCTAssertTrue(html.contains("2023"))
        XCTAssertFalse(html.contains("Mac-A"), "a year's count, not the Macs in it")
    }

    func testPurchaseCohortsAreLeftOutWithoutPurchaseDates() {
        let none = makeReport().buildPurchaseCohorts(computersInventory: [])
        XCTAssertTrue(none.html.isEmpty)
        XCTAssertEqual(none.omission, "no purchase dates in the inventory")
        let undated = makeReport().buildPurchaseCohorts(computersInventory: [["name": "Mac"]])
        XCTAssertEqual(undated.omission, "no purchase dates in the inventory")
    }

    func testPurchaseCohortsXSS() {
        let report = makeReport()
        let inventory: [[String: Any]] = [
            ["name": Self.xssPayload, "purchase_date": "2024-01-01"],
        ]
        let html = report.buildPurchaseCohorts(computersInventory: inventory).html
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
        let html = report.buildBuildingBreakdown(computersInventory: inventory).html
        XCTAssertTrue(html.contains("building-breakdown"))
        XCTAssertTrue(html.contains("cohort-bar-row"))
        XCTAssertTrue(html.contains("HQ"))
        XCTAssertTrue(html.contains("Remote"))
    }

    func testBuildingBreakdownIsLeftOutWithoutComputers() {
        let block = makeReport().buildBuildingBreakdown(computersInventory: [])
        XCTAssertTrue(block.html.isEmpty)
        XCTAssertEqual(block.omission, "no computers snapshot")
    }

    /// One "(unassigned)" bar for the whole fleet says nothing, so the section is left out.
    func testBreakdownsAreLeftOutWhenEveryMacIsUnassigned() {
        let inventory: [[String: Any]] = [["name": "M1"], ["name": "M2"]]
        let buildings = makeReport().buildBuildingBreakdown(computersInventory: inventory)
        XCTAssertTrue(buildings.html.isEmpty)
        XCTAssertEqual(buildings.omission, "every Mac is unassigned")
        XCTAssertEqual(
            makeReport().buildDepartmentBreakdown(computersInventory: inventory).omission,
            "every Mac is unassigned")
    }

    func testBuildingBreakdownKeepsUnassignedBesideRealBuildings() {
        let inventory: [[String: Any]] = [["name": "M1", "building": "HQ"], ["name": "M2"]]
        let html = makeReport().buildBuildingBreakdown(computersInventory: inventory).html
        XCTAssertTrue(html.contains("(unassigned)"))
        XCTAssertTrue(html.contains("HQ"))
    }

    func testBuildingBreakdownXSS() {
        let report = makeReport()
        let inventory: [[String: Any]] = [
            ["name": "M1", "building": Self.xssPayload],
        ]
        let html = report.buildBuildingBreakdown(computersInventory: inventory).html
        XCTAssertFalse(html.contains("<script>"))
    }

    func testBuildingBreakdownStableOutput() {
        let report = makeReport()
        let inv: [[String: Any]] = [["name": "M", "building": "B"]]
        XCTAssertEqual(
            report.buildBuildingBreakdown(computersInventory: inv).html,
            report.buildBuildingBreakdown(computersInventory: inv).html
        )
    }

    /// Twelve buildings: ten bars show, the other two sit behind "Show all 12".
    func testBreakdownBarsShowTenAndKeepTheRestBehindShowAll() {
        let inventory: [[String: Any]] = (0..<12).map { ["name": "M\($0)", "building": "B\($0)"] }
        let html = makeReport().buildBuildingBreakdown(computersInventory: inventory).html
        let (shown, rest) = Self.splitAtShowAll(html)
        XCTAssertEqual(shown.components(separatedBy: "cohort-bar-row").count - 1, 10)
        XCTAssertEqual(rest.components(separatedBy: "cohort-bar-row").count - 1, 2)
        XCTAssertTrue(html.contains("<summary>Show all 12</summary>"))
    }

    // MARK: - departmentBreakdown

    func testDepartmentBreakdownWithData() {
        let report = makeReport()
        let inventory: [[String: Any]] = [
            ["name": "M1", "department": "Engineering"],
            ["name": "M2", "department": "Engineering"],
            ["name": "M3", "department": "Finance"],
        ]
        let html = report.buildDepartmentBreakdown(computersInventory: inventory).html
        XCTAssertTrue(html.contains("department-breakdown"))
        XCTAssertTrue(html.contains("cohort-bar-row"))
        XCTAssertTrue(html.contains("Engineering"))
        XCTAssertTrue(html.contains("Finance"))
    }

    func testDepartmentBreakdownXSS() {
        let report = makeReport()
        let inventory: [[String: Any]] = [
            ["name": "M1", "department": Self.xssPayload],
        ]
        let html = report.buildDepartmentBreakdown(computersInventory: inventory).html
        XCTAssertFalse(html.contains("<script>"))
    }

    // MARK: - protectAlerts

    func testProtectAlertsAreLeftOutWhenProtectIsNotConfigured() {
        let block = makeReport().buildProtectAlerts(protectDataDir: nil)
        XCTAssertTrue(block.html.isEmpty)
        XCTAssertEqual(block.omission, "not configured: protect.enabled is off in config.yaml")
    }

    func testProtectAlertsEmptyCache() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProtectAlertTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let block = makeReport().buildProtectAlerts(protectDataDir: tmp)
        XCTAssertTrue(block.html.isEmpty)
        XCTAssertEqual(block.omission, "no Protect alerts in the snapshot")
        XCTAssertFalse(block.omission?.contains("jamf-cli protect collect") == true,
            "the reason must not name a command jamf-cli does not have")
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

        let html = makeReport().buildProtectAlerts(protectDataDir: tmp).html

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
        XCTAssertEqual(a.html, b.html)
        XCTAssertEqual(a.omission, b.omission)
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
        let html = report.buildProtectAlerts(protectDataDir: tmp).html

        XCTAssertTrue(html.contains("Mac-Dev-01"), "Should render the computer host name")
        XCTAssertTrue(html.contains("Malware Detected"), "Should render eventType as the alert")
        XCTAssertTrue(html.contains("2026-04-01"), "Date should be the first 10 chars of created")
        XCTAssertTrue(html.contains("Suspicious Script, Persistence"),
            "Should fall back to analytics when eventType is empty")
        XCTAssertTrue(html.contains("<td>—</td><td>Suspicious Script, Persistence</td>"),
            "An alert with no computer must still render its row")
    }

    // MARK: - insightsDrift

    func testInsightsDriftIsLeftOutWhenProtectIsNotConfigured() {
        let block = makeReport().buildInsightsDrift(protectDataDir: nil)
        XCTAssertTrue(block.html.isEmpty)
        XCTAssertEqual(block.omission, "not configured: protect.enabled is off in config.yaml")
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

        let block = makeReport().buildInsightsDrift(protectDataDir: tmp)
        XCTAssertTrue(block.html.isEmpty)
        XCTAssertEqual(block.omission,
                       "needs two or more Protect insights snapshots; 1 found")
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
        let html = report.buildInsightsDrift(protectDataDir: tmp).html
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
        let html = report.buildInsightsDrift(protectDataDir: tmp).html

        XCTAssertTrue(html.contains("Unsigned Kernel Extension"))
        XCTAssertTrue(html.contains("failing-device counts"),
            "Table must say plainly that the numbers are failing-device counts")
        XCTAssertTrue(html.contains(">10<"), "Previous day's totalFail (10) must render")
        XCTAssertTrue(html.contains(">3<"), "Current day's totalFail (3) must render")
    }

    /// renderTable escapes every cell, so the rows hold plain text. Escaped first as well,
    /// a label with `&` read "&amp;" in the report.
    func testInsightsDriftEscapesALabelOnce() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("InsightsDriftEscape-\(UUID().uuidString)", isDirectory: true)
        let insightsDir = tmp.appendingPathComponent("protect-insights", isDirectory: true)
        try FileManager.default.createDirectory(at: insightsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let label = "Gatekeeper & XProtect <script>alert(1)</script>"
        for (stamp, fail) in [("20260401T000000", 4), ("20260402T000000", 2)] {
            let rows: [[String: Any]] = [["label": label, "section": "System", "enabled": true,
                                          "totalPass": 90, "totalFail": fail, "totalNone": 0]]
            try JSONSerialization.data(withJSONObject: rows).write(
                to: insightsDir.appendingPathComponent("protect-insights_\(stamp).json"))
        }

        let html = makeReport().buildInsightsDrift(protectDataDir: tmp).html

        XCTAssertTrue(html.contains("Gatekeeper &amp; XProtect &lt;script&gt;"), html)
        XCTAssertFalse(html.contains("&amp;amp;"), "the label was escaped twice")
        XCTAssertFalse(html.contains("<script>alert"), "the label must still be escaped")
    }

    // MARK: - agentHealth

    private static let falconYAML = """
    security_agents:
      - name: "Falcon"
        column: "Falcon State"
        connected_value: "connected"
    """

    private func eaRows(_ rows: [(String, String, String)]) throws -> [EAResultRow] {
        let json = rows.map { id, ea, value in
            ["computer_id": id, "ea_name": ea, "value": value]
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try XCTUnwrap(EAResultRow.decodeSnapshot(data).rows)
    }

    func testAgentHealthIsLeftOutWhenNoAgentIsConfigured() {
        let block = makeReport().buildAgentHealth(eaRows: [], fleet: 0)
        XCTAssertTrue(block.html.isEmpty)
        XCTAssertEqual(block.omission, "not configured: no security_agents in config.yaml")
    }

    /// Four Macs, three report: two connected, one not. The fourth reports nothing.
    func testAgentHealthCountsFromEAResultsOverTheFleet() throws {
        let report = makeReport(config: try ConfigLoader.loadFromString(Self.falconYAML))
        let rows = try eaRows([
            ("1", "Falcon State", "connected"), ("2", "Falcon State", "Connected (sensor)"),
            ("3", "Falcon State", "not installed"), ("1", "Other EA", "x"),
        ])
        let html = report.buildAgentHealth(eaRows: rows, fleet: 4).html
        XCTAssertTrue(html.contains("count-card"))
        XCTAssertTrue(html.contains("2 of 4 installed"), html)
        XCTAssertTrue(html.contains("<td>Falcon</td><td>2</td><td>1</td><td>1</td><td>50.0%</td>"),
                      html)
    }

    /// "Not Installed" reads as off, so it is not connected though it contains "Installed".
    func testAgentHealthDoesNotCountANegatedValueAsInstalled() throws {
        let yaml = """
        security_agents:
          - name: "Nessus"
            column: "Nessus Status"
            connected_value: "Installed"
        """
        let report = makeReport(config: try ConfigLoader.loadFromString(yaml))
        let rows = try eaRows([
            ("1", "Nessus Status", "Installed"), ("2", "Nessus Status", "Installed"),
            ("3", "Nessus Status", "Not Installed"), ("4", "Nessus Status", "Not Installed"),
            ("5", "Nessus Status", "Not Installed"),
        ])
        let html = report.buildAgentHealth(eaRows: rows, fleet: 5).html
        XCTAssertTrue(html.contains("40.0%"), html)
        XCTAssertFalse(html.contains("100.0%"))
    }

    /// No Mac reports the configured column (usually a mistyped name): nothing to chart, so
    /// the section is left out and the appendix names the column that matched nothing.
    func testAgentHealthIsLeftOutWhenNoMacReportsTheColumn() throws {
        let report = makeReport(config: try ConfigLoader.loadFromString(Self.falconYAML))
        let rows = try eaRows([("1", "Unrelated EA", "connected")])
        let block = report.buildAgentHealth(eaRows: rows, fleet: 10)
        XCTAssertTrue(block.html.isEmpty)
        XCTAssertEqual(
            block.omission,
            "no Mac reports the extension attribute of any configured agent (Falcon State)")
    }

    /// One agent reports and one does not: the section stays and says which has no coverage.
    func testAgentHealthKeepsAnAgentNoMacReportsBesideOneThatDoes() throws {
        let yaml = Self.falconYAML + """

          - name: "Nessus"
            column: "Nessus Status"
            connected_value: "Installed"
        """
        let report = makeReport(config: try ConfigLoader.loadFromString(yaml))
        let rows = try eaRows([("1", "Falcon State", "connected")])
        let html = report.buildAgentHealth(eaRows: rows, fleet: 10).html
        XCTAssertTrue(html.contains("no Mac reports Nessus Status"), html)
        XCTAssertTrue(
            html.contains("<td>Nessus</td><td>0</td><td>0</td><td>10</td><td>\u{2014}</td>"), html)
    }

    func testAgentHealthWithoutEAResultsSaysSoInsteadOfCountingZero() throws {
        let report = makeReport(config: try ConfigLoader.loadFromString(Self.falconYAML))
        let block = report.buildAgentHealth(eaRows: nil, fleet: 665)
        XCTAssertTrue(block.html.isEmpty)
        XCTAssertEqual(block.omission, "no extension attribute results in the snapshot")
    }

    func testAgentHealthXSS() throws {
        let yaml = """
        security_agents:
          - name: "<script>alert(1)</script>"
            column: "Status"
            connected_value: "Up"
        """
        let report = makeReport(config: try ConfigLoader.loadFromString(yaml))
        let rows = try eaRows([("1", "Status", "Up")])
        let html = report.buildAgentHealth(eaRows: rows, fleet: 1).html
        XCTAssertFalse(html.contains("<script>"))
    }

    func testAgentHealthStableOutput() throws {
        let report = makeReport(config: try ConfigLoader.loadFromString(Self.falconYAML))
        let rows = try eaRows([("1", "Falcon State", "connected")])
        XCTAssertEqual(
            report.buildAgentHealth(eaRows: rows, fleet: 2).html,
            report.buildAgentHealth(eaRows: rows, fleet: 2).html
        )
    }

}
