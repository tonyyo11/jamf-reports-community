import XCTest
@testable import JamfReports

/// What the PDF prints: one table per list, cell text that wraps inside the page, and groups
/// that start on a new page (prod's beta 4 PDF cut the follow-up table's last three columns,
/// split capped lists into two tables under a dead "Show all" label, and left group and block
/// headings at the foot of a page).
final class HtmlPrintLayoutTests: XCTestCase {
    private typealias F = HtmlSectionFormatters

    func testAnExpandedCappedListIsOneTableWithNoShowAllLabel() {
        let rows = (1...30).map { ["Mac-\($0)", "\($0)"] }
        let printed = F.renderCappedTable(headers: ["Device", "Days"], rows: rows, expanded: true)
        XCTAssertEqual(printed.components(separatedBy: "<table").count - 1, 1)
        XCTAssertFalse(printed.contains("Show"))
        XCTAssertTrue(printed.contains("Mac-30"))

        let screen = F.renderCappedTable(headers: ["Device", "Days"], rows: rows)
        XCTAssertEqual(screen.components(separatedBy: "<table").count - 1, 2)
        XCTAssertTrue(screen.contains("Show all 30"))
    }

    func testExpandedShowAllAndCappedRowsPrintTheRestWithoutALabel() {
        XCTAssertEqual(F.showAll(count: 12, body: "<p>rest</p>", expanded: true), "<p>rest</p>")
        let rowHTML = (1...12).map { "<tr><td>\($0)</td></tr>" }
        let printed = F.renderCappedRows(headers: ["N"], rowHTML: rowHTML, expanded: true)
        XCTAssertEqual(printed.components(separatedBy: "<table").count - 1, 1)
        XCTAssertFalse(printed.contains("Show all"))
    }

    func testOnlyLongWordsInATableCellGetBreakPoints() {
        XCTAssertEqual(
            F.escapeHTMLLongWords("JESSICA.JIMENEZ@cbp.example.gov"),
            "JESSICA.<wbr>JIMENEZ@<wbr>cbp.<wbr>example.<wbr>gov")
        XCTAssertEqual(F.escapeHTMLLongWords("75.0%"), "75.0%")
        XCTAssertEqual(F.escapeHTMLLongWords("LATEST_MAJOR"), "LATEST_MAJOR")
        XCTAssertEqual(F.escapeHTMLLongWords("C02CM96LMD6M"), "C02CM96LMD6M")
        XCTAssertEqual(F.escapeHTMLLongWords("Inventory not updating"), "Inventory not updating")
        XCTAssertTrue(F.renderTable(headers: ["User"], rows: [["someone.long@example.org"]])
            .contains("someone.<wbr>long@<wbr>example.<wbr>org"))
        XCTAssertEqual(F.escapeHTMLLongWords("<script>alert(1)</script>-padding"),
                       "&lt;script&gt;alert(1)&lt;/<wbr>script&gt;-padding")
    }

    func testTheFullInstancePDFStartsEachGroupOnANewPageButNotTheDashboardNote() {
        XCTAssertEqual(FullInstanceTemplate().pdfPagination, .sectionPerPage)
        let css = ReportEngine.applyPagination(
            html: "<html><head></head></html>", strategy: .sectionPerPage)
        XCTAssertTrue(css.contains("details.group:not(.dashboard)"))
    }
}
