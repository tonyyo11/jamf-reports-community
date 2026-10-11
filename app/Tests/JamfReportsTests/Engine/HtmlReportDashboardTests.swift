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

    /// The dashboard section's markup and, when there is none to show, why not.
    private func section() -> (html: String, omission: String?) {
        switch report().dashboardState() {
        case .embedded(let html), .notEmbedded(let html): return (html, nil)
        case .absent(let reason): return ("", reason)
        }
    }

    private func writePage(_ html: String, stamp: String, modified: Date? = nil) throws {
        let dir = dataDir.appendingPathComponent("dashboard", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("dashboard_\(stamp).html")
        try html.write(to: file, atomically: true, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes(
                [.modificationDate: modified], ofItemAtPath: file.path)
        }
    }

    /// No page, no section: the appendix carries the reason instead of an empty box.
    func testWithoutASnapshotTheSectionIsLeftOutWithItsReason() {
        let block = section()
        XCTAssertTrue(block.html.isEmpty)
        XCTAssertTrue(block.omission?.hasPrefix("not collected yet") == true, block.omission ?? "")
    }

    /// File dates disagree with the filename stamps on purpose, as a sync provider's
    /// re-stamping makes them: the newest-stamped page is the oldest file and the
    /// conflict copy is the newest, so a picker ordering by mtime takes the wrong page.
    func testTheNewestPageIsEmbeddedEscapedInASandboxedFrame() throws {
        let day = TimeInterval(86_400)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try writePage(
            "<!DOCTYPE html><html><head><title>t</title></head>"
                + "<body class=\"x\">A &amp; B</body></html>",
            stamp: "20260925T060000", modified: base)
        try writePage(
            "<!DOCTYPE html><html><head><title>t</title></head><body>OLDPAGE</body></html>",
            stamp: "20260901T060000", modified: base + day)
        try writePage(
            "<!DOCTYPE html><html><head><title>t</title></head><body>CONFLICT</body></html>",
            stamp: "20260925T060000 2", modified: base + 2 * day)
        let dir = dataDir.appendingPathComponent("dashboard", isDirectory: true)
        let dates = try ["dashboard_20260925T060000.html", "dashboard_20260901T060000.html",
                         "dashboard_20260925T060000 2.html"].map { name in
            try XCTUnwrap(FileManager.default.attributesOfItem(
                atPath: dir.appendingPathComponent(name).path)[.modificationDate] as? Date)
        }
        XCTAssertEqual(dates, dates.sorted(), "file dates run opposite to the stamps")
        XCTAssertEqual(Set(dates).count, 3)
        let html = section().html
        XCTAssertTrue(html.contains("sandbox=\"allow-scripts\""), html)
        XCTAssertFalse(html.contains("allow-same-origin"), "the page must not reach the report")
        XCTAssertFalse(html.contains("OLDPAGE"), "the newest stamp wins, not the newest file")
        XCTAssertFalse(html.contains("CONFLICT"), "a sync-conflict copy is never picked")
        XCTAssertTrue(html.contains("&lt;body class=&quot;x&quot;&gt;A &amp;amp; B"),
                      "the page is escaped once for the srcdoc attribute")
    }

    func testAloneASyncConflictCopyIsNotEmbedded() throws {
        try writePage("<!DOCTYPE html><html><head></head><body>CONFLICT</body></html>",
                      stamp: "20260925T060000 2")
        let block = section()
        XCTAssertTrue(block.omission?.hasPrefix("not collected yet") == true)
        XCTAssertFalse(block.html.contains("<iframe"))
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
        let theme = try XCTUnwrap(page.range(of: "<script id=\"jrc-embed-theme\">"))
        XCTAssertLessThan(theme.lowerBound, headEnd.lowerBound)
    }

    /// The report is light unless the reader picks dark and the page follows the Mac,
    /// so the report's switch drives the frame and the page's own switch is hidden.
    func testTheReportsThemeSwitchDrivesTheFrame() throws {
        let page = HtmlReport.dashboardPageForEmbedding("<html><head></head><body></body></html>")
        XCTAssertTrue(page.contains(".theme-toggle{display:none!important}"))
        XCTAssertTrue(page.contains("d.setAttribute(\"data-theme\",\"light\")"),
                      "the page starts on the report's default")
        XCTAssertTrue(page.contains("if(e.source!==parent||!e.data){return;}"),
                      "the page takes a theme only from the report")
        XCTAssertTrue(page.contains("if(t===\"light\"||t===\"dark\")"))

        try writePage("<!DOCTYPE html><html><head></head><body></body></html>",
                      stamp: "20260925T060000")
        let html = section().html
        XCTAssertTrue(html.contains("frame.addEventListener(\"load\", sendTheme)"), html)
        XCTAssertTrue(html.contains("new MutationObserver(sendTheme)"))
        XCTAssertTrue(html.contains("attributeFilter: [\"data-theme\"]"))
    }

    private static let policy = "default-src 'none'; style-src 'unsafe-inline'; "
        + "script-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'"
    private static let policyMeta =
        "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"
    private static let framePrefix = "<!DOCTYPE html>" + policyMeta

    func testAPageWithoutAHeadGetsOneWithThePolicyAndTheAdditions() {
        let page = HtmlReport.dashboardPageForEmbedding("<p>x</p>")
        XCTAssertTrue(
            page.hasPrefix(Self.framePrefix + "<head><style id=\"jrc-embed\">"), page)
        XCTAssertTrue(page.hasSuffix("</head><p>x</p>"))
    }

    /// The frame is scripted, so without a policy the page could fetch or post anywhere.
    /// A meta policy ignores what precedes it, so it is the first thing in the frame
    /// whatever the page holds, not the first thing a regex finds in it.
    func testThePolicyIsAPrefixAtByteZeroWhateverThePageHolds() throws {
        XCTAssertEqual(HtmlReport.reportContentSecurityPolicy, Self.policy)
        let pages = [
            "<!DOCTYPE html><html><head><title>t</title></head><body></body></html>",
            "<html><HEAD lang=\"en\"><title>t</title></HEAD><body></body></html>",
            "<html><Head\n  data-x='1'\n><title>t</title></head><body></body></html>",
            "<!--<head>--><!DOCTYPE html><html><head></head><body></body></html>",
            "<script>var a;</script><html><head></head><body></body></html>",
            "<html><head><title>t</title><body>",
            "<header>x</header><body></body>",
            "<p>no head at all</p>",
            "",
        ]
        for source in pages {
            let page = HtmlReport.dashboardPageForEmbedding(source)
            XCTAssertTrue(page.hasPrefix(Self.framePrefix), "\(source)\n\(page)")
            XCTAssertEqual(
                page.components(separatedBy: "Content-Security-Policy").count, 2, source)
        }
    }

    func testAPageStartingWithACommentedHeadStillStartsWithThePolicy() {
        let page = HtmlReport.dashboardPageForEmbedding(
            "<!--<head>--><html><head></head><body></body></html>")
        XCTAssertTrue(page.hasPrefix(Self.framePrefix + "<!--<head>-->"), page)
    }

    func testAPageStartingWithAScriptStillStartsWithThePolicy() {
        let page = HtmlReport.dashboardPageForEmbedding(
            "<script>fetch('http://x')</script><html><head></head></html>")
        XCTAssertTrue(page.hasPrefix(Self.framePrefix + "<script>fetch("), page)
    }

    /// `<header>` and `<head-x>` start with `<head` but are not the head.
    func testAHeaderElementIsNotTakenForTheHead() {
        let page = HtmlReport.dashboardPageForEmbedding("<header>x</header><body></body>")
        XCTAssertTrue(page.hasPrefix(Self.framePrefix + "<head>"), page)
        XCTAssertTrue(page.hasSuffix("</head><header>x</header><body></body>"), page)
    }

    func testAHeadWithoutAClosingTagStillGetsTheAdditionsInside() {
        let page = HtmlReport.dashboardPageForEmbedding("<html><head><title>t</title><body>")
        XCTAssertTrue(page.hasPrefix(Self.framePrefix + "<html><head><style id=\"jrc-embed\">"),
                      page)
        XCTAssertTrue(page.hasSuffix("<title>t</title><body>"), page)
    }

    func testTheEmbeddedFrameCarriesThePolicy() throws {
        try writePage("<!DOCTYPE html><html><head></head><body></body></html>",
                      stamp: "20260925T060000")
        let html = section().html
        XCTAssertTrue(html.contains(
            "srcdoc=\"&lt;!DOCTYPE html&gt;&lt;meta http-equiv=&quot;Content-Security-Policy&quot;"),
            html)
    }

    /// The frame inherits the report's policy, so the report carries one: a single meta
    /// in the head, ahead of the first style or script.
    func testTheReportCarriesOneContentSecurityPolicyAheadOfStylesAndScripts() async throws {
        let out = dataDir.appendingPathComponent("report.html")
        _ = try await report().generate(outputURL: out)
        let text = try String(contentsOf: out, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "Content-Security-Policy").count, 2)
        XCTAssertTrue(text.contains(HtmlReport.reportContentSecurityPolicyMeta))
        let head = try XCTUnwrap(text.range(of: "<head>"))
        let headEnd = try XCTUnwrap(text.range(of: "</head>"))
        let meta = try XCTUnwrap(text.range(of: "Content-Security-Policy"))
        XCTAssertTrue(head.upperBound <= meta.lowerBound && meta.upperBound <= headEnd.lowerBound)
        for tag in ["<style", "<script"] {
            let first = try XCTUnwrap(text.range(of: tag))
            XCTAssertLessThan(meta.lowerBound, first.lowerBound, tag)
        }
    }

    func testAnOversizedPageIsNamedNotEmbedded() throws {
        let filler = String(repeating: "a", count: HtmlReport.maxEmbeddedDashboardBytes)
        try writePage("<!DOCTYPE html><html><body>\(filler)</body></html>",
                      stamp: "20260925T060000")
        let html = section().html
        XCTAssertTrue(html.contains("too large to embed"), String(html.prefix(400)))
        XCTAssertTrue(html.contains("dashboard_20260925T060000.html"))
        XCTAssertFalse(html.contains("<iframe"))
    }

    func testPrintingShowsANoteAndTheFrameTrustsOnlyItself() throws {
        try writePage("<!DOCTYPE html><html><head></head><body></body></html>",
                      stamp: "20260925T060000")
        let html = section().html
        XCTAssertTrue(html.contains("@media print"))
        XCTAssertTrue(html.contains("jrc-dashboard-print-note"))
        XCTAssertTrue(html.contains(
            "#jamf-dashboard .jrc-dashboard-wrap { display: none !important; }"))
        XCTAssertTrue(html.contains("event.source !== frame.contentWindow"))
        let tag = try XCTUnwrap(html.range(of: "<iframe id=\"jrc-dashboard-frame\""))
        let srcdoc = try XCTUnwrap(html.range(of: "srcdoc=", range: tag.upperBound..<html.endIndex))
        XCTAssertFalse(html[tag.upperBound..<srcdoc.lowerBound].contains("style="),
                       "an inline display on the frame beats the print rule")
    }

    /// The page reports its body's height and the report uses it as is. A document is
    /// never shorter than its frame, so reporting that, plus padding, grew the frame on
    /// every resize until the cap.
    func testTheFrameTakesThePageBodysHeightWithoutPadding() throws {
        let script = HtmlReport.dashboardHeightScript
        XCTAssertTrue(script.contains("document.body"))
        XCTAssertFalse(script.contains("scrollHeight"), "the document's height feeds back")
        XCTAssertTrue(script.contains("ResizeObserver"), "a collapsed section must shrink it")
        try writePage("<!DOCTYPE html><html><head></head><body></body></html>",
                      stamp: "20260925T060000")
        let html = section().html
        XCTAssertTrue(html.contains("Math.max(400, Math.min(Math.ceil(height), 40000))"), html)
        XCTAssertTrue(html.contains("Math.abs(frame.clientHeight - clamped) > 2"))
        XCTAssertTrue(html.contains("border: 0;"), "the border sits on the wrapper")
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
