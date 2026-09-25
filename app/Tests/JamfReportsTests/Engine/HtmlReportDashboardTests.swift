import XCTest
@testable import JamfReports

/// The HTML report's jamf-cli dashboard section: which snapshot it embeds, how, and
/// what it says when there is nothing to embed.
final class HtmlReportDashboardTests: XCTestCase {

    private var dataDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dataDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-DashHTML-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dataDir)
        try super.tearDownWithError()
    }

    private func report() -> HtmlReport {
        HtmlReport(config: ReportConfig().withDefaults(), dataDir: dataDir)
    }

    private func writePage(_ html: String, stamp: String) throws {
        let dir = dataDir.appendingPathComponent("dashboard", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try html.write(to: dir.appendingPathComponent("dashboard_\(stamp).html"),
                       atomically: true, encoding: .utf8)
    }

    func testWithoutASnapshotTheSectionSaysSo() {
        let html = report().buildJamfDashboardSection()
        XCTAssertTrue(html.contains("Not collected yet"), html)
        XCTAssertFalse(html.contains("<iframe"))
    }

    func testTheNewestPageIsEmbeddedEscapedInASandboxedFrame() throws {
        try writePage(
            "<!DOCTYPE html><html><head><title>t</title></head><body>OLDPAGE</body></html>",
            stamp: "20260901T060000")
        try writePage(
            "<!DOCTYPE html><html><head><title>t</title></head>"
                + "<body class=\"x\">A &amp; B</body></html>",
            stamp: "20260925T060000")
        let html = report().buildJamfDashboardSection()
        XCTAssertTrue(html.contains("sandbox=\"allow-scripts\""), html)
        XCTAssertFalse(html.contains("allow-same-origin"), "the page must not reach the report")
        XCTAssertFalse(html.contains("OLDPAGE"), "the newest stamp wins")
        XCTAssertTrue(html.contains("&lt;body class=&quot;x&quot;&gt;A &amp;amp; B"),
                      "the page is escaped once for the srcdoc attribute")
    }

    func testTheAdditionsGoAtTheEndOfTheHead() throws {
        let page = HtmlReport.dashboardPageForEmbedding(
            "<html><head><title>t</title></HEAD><body></body></html>")
        let style = try XCTUnwrap(page.range(of: "<style id=\"jrc-embed\">"))
        let headEnd = try XCTUnwrap(page.range(of: "</HEAD>"))
        XCTAssertLessThan(style.lowerBound, headEnd.lowerBound)
        XCTAssertTrue(page.contains(".section{opacity:1!important;animation:none!important}"))
        XCTAssertTrue(page.contains(".ring{--rv:var(--v)!important;animation:none!important}"))
        XCTAssertTrue(page.contains("jrcDashboardHeight"))
    }

    func testAPageWithoutAHeadGetsTheAdditionsFirst() {
        let page = HtmlReport.dashboardPageForEmbedding("<p>x</p>")
        XCTAssertTrue(page.hasPrefix("<style id=\"jrc-embed\">"))
        XCTAssertTrue(page.hasSuffix("<p>x</p>"))
    }

    func testAnOversizedPageIsNamedNotEmbedded() throws {
        let filler = String(repeating: "a", count: HtmlReport.maxEmbeddedDashboardBytes)
        try writePage("<!DOCTYPE html><html><body>\(filler)</body></html>",
                      stamp: "20260925T060000")
        let html = report().buildJamfDashboardSection()
        XCTAssertTrue(html.contains("too large to embed"), String(html.prefix(400)))
        XCTAssertTrue(html.contains("dashboard_20260925T060000.html"))
        XCTAssertFalse(html.contains("<iframe"))
    }

    func testPrintingShowsANoteAndTheFrameTrustsOnlyItself() throws {
        try writePage("<!DOCTYPE html><html><head></head><body></body></html>",
                      stamp: "20260925T060000")
        let html = report().buildJamfDashboardSection()
        XCTAssertTrue(html.contains("@media print"))
        XCTAssertTrue(html.contains("jrc-dashboard-print-note"))
        XCTAssertTrue(html.contains("event.source !== frame.contentWindow"))
    }

    func testTheTemplatedReportRendersTheSection() async throws {
        try writePage("<!DOCTYPE html><html><head></head><body>FLEET</body></html>",
                      stamp: "20260925T060000")
        let out = dataDir.appendingPathComponent("report.html")
        try await report().generate(outputURL: out, profileName: "p", sections: [.jamfDashboard])
        let html = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(html.contains("Jamf Fleet Dashboard"))
        XCTAssertTrue(html.contains("id=\"jrc-dashboard-frame\""))
        XCTAssertTrue(FullInstanceTemplate().htmlSections.contains(.jamfDashboard))
    }
}
