import PDFKit
import XCTest
@testable import JamfReports

// MARK: - PDFExporterTests

/// Tests for PDFExporter HTML-to-PDF conversion via WKWebView.createPDF.
///
/// All tests run on the main actor because WKWebView is main-thread-only.
/// A 15-second test timeout guards against WKWebView load hangs.
@MainActor
final class PDFExporterTests: XCTestCase {

    private nonisolated(unsafe) var outputDir: URL!

    override func setUpWithError() throws {
        outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFExporterTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: outputDir)
    }

    // MARK: - Tests

    /// A minimal HTML document must produce a file whose first five bytes are `%PDF-`.
    func testExportSimpleHTMLProducesValidPDF() async throws {
        let html = "<html><body><h1>Hello, Compliance</h1></body></html>"
        let dest = outputDir.appendingPathComponent("simple.pdf")

        try await PDFExporter.export(htmlString: html, to: dest)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path),
                      "PDF file should exist at \(dest.path)")
        let magic = try Data(contentsOf: dest).prefix(5)
        XCTAssertEqual(String(bytes: magic, encoding: .ascii), "%PDF-",
                       "Output should begin with PDF magic bytes")
    }

    /// An empty HTML string is permissive — WKWebView loads it without error and
    /// produces a valid (possibly blank) PDF rather than throwing.
    func testExportEmptyHTMLStringProducesFile() async throws {
        let dest = outputDir.appendingPathComponent("empty.pdf")

        try await PDFExporter.export(htmlString: "", to: dest)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path),
                      "PDF file should exist even for empty HTML")
    }

    /// Generated PDFs must exceed 1 KB — a valid PDF with any content will be larger.
    func testPDFFileIsNonZeroSize() async throws {
        let html = """
        <html>
        <head><style>body { font-family: sans-serif; }</style></head>
        <body>
          <h1>Jamf Instance Report</h1>
          <table>
            <tr><th>Device</th><th>Status</th></tr>
            <tr><td>MacBook-001</td><td>Compliant</td></tr>
          </table>
        </body>
        </html>
        """
        let dest = outputDir.appendingPathComponent("sized.pdf")

        try await PDFExporter.export(htmlString: html, to: dest)

        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 1024, "PDF must be larger than 1 KB, got \(size) bytes")
    }

    /// Exporting from a file URL backed by a known-good HTML file should succeed.
    func testExportFromFileURL() async throws {
        let htmlFile = outputDir.appendingPathComponent("source.html")
        let html = "<html><body><p>File URL export test</p></body></html>"
        try html.write(to: htmlFile, atomically: true, encoding: .utf8)

        let dest = outputDir.appendingPathComponent("from_file.pdf")
        try await PDFExporter.export(htmlURL: htmlFile, to: dest)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        let magic = try Data(contentsOf: dest).prefix(5)
        XCTAssertEqual(String(bytes: magic, encoding: .ascii), "%PDF-")
    }

    /// The exporter should create intermediate directories if the destination path
    /// does not yet exist.
    func testExportCreatesIntermediateDirectories() async throws {
        let nested = outputDir
            .appendingPathComponent("a/b/c", isDirectory: true)
            .appendingPathComponent("report.pdf")
        let html = "<html><body>Nested</body></html>"

        try await PDFExporter.export(htmlString: html, to: nested)

        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path),
                      "File should exist after creating intermediate directories")
    }

    // MARK: - Pagination

    private func exportedDocument(_ html: String, name: String) async throws -> PDFDocument {
        let dest = outputDir.appendingPathComponent(name)
        try await PDFExporter.export(htmlString: html, to: dest)
        return try XCTUnwrap(PDFDocument(url: dest), "no readable PDF at \(dest.path)")
    }

    /// A document longer than a page fills as many pages as it needs, each with text, and
    /// its last line lands on the last page (the export held only the first page before).
    func testALongDocumentFillsSeveralPages() async throws {
        let rows = (1...200).map { "<p>Row \($0) of the long report</p>" }.joined()
        let doc = try await exportedDocument(
            "<html><body>\(rows)<p>END-OF-REPORT</p></body></html>", name: "long.pdf")
        XCTAssertGreaterThan(doc.pageCount, 3)
        for index in 0..<doc.pageCount {
            XCTAssertFalse((doc.page(at: index)?.string ?? "").isEmpty, "page \(index) is blank")
        }
        XCTAssertTrue(doc.page(at: doc.pageCount - 1)?.string?.contains("END-OF-REPORT") == true)
    }

    /// The template's page breaks (`ReportEngine.applyPagination`) start a new page.
    func testACSSPageBreakStartsANewPage() async throws {
        let html = """
        <html><head><style>section { page-break-after: always; }
        section:last-of-type { page-break-after: avoid; }</style></head>
        <body><section>First section</section><section>Second section</section></body></html>
        """
        let doc = try await exportedDocument(html, name: "breaks.pdf")
        XCTAssertEqual(doc.pageCount, 2)
        XCTAssertTrue(doc.page(at: 0)?.string?.contains("First section") == true)
        XCTAssertTrue(doc.page(at: 1)?.string?.contains("Second section") == true)
    }

    /// One section per page: the summary blocks share the first page and each detail group
    /// starts its own, with no empty page after the last.
    func testSectionPerPageKeepsTheSummaryTogetherAndGivesEachGroupAPage() async throws {
        func group(_ name: String) -> String {
            "<section class=\"group-section\"><details class=\"group\" open>" +
                "<summary>\(name)</summary><p>\(name) body</p></details></section>"
        }
        let html = ReportEngine.applyPagination(html: """
            <html><head></head><body><main>
            <section class="summary-block"><p>At a glance</p></section>
            <section class="summary-block"><p>Needs attention</p></section>
            \(group("Security group"))\(group("Patching group"))
            </main></body></html>
            """, strategy: .sectionPerPage)
        let doc = try await exportedDocument(html, name: "section-per-page.pdf")
        XCTAssertEqual(doc.pageCount, 3)
        let first = doc.page(at: 0)?.string ?? ""
        XCTAssertTrue(first.contains("At a glance") && first.contains("Needs attention"))
        XCTAssertTrue(doc.page(at: 1)?.string?.contains("Security group body") == true)
        XCTAssertTrue(doc.page(at: 2)?.string?.contains("Patching group body") == true)
    }

    /// With the report's print CSS, a block shorter than a page is not split by a page break:
    /// whichever height the spacer puts the heading at, it stays on a page with its table's
    /// header and first row. (Without the rule the heading fell alone, or with only the
    /// header row, at the foot of a page for spacers of about 800 to 840 points.)
    func testAShortBlockKeepsItsHeadingWithItsTable() async throws {
        let css = HtmlReport(config: ReportConfig().withDefaults(), dataDir: outputDir)
            .buildCSS(accentColor: "#2D5EA2")
        let rows = (1...12).map { "<tr><td>row-\($0)</td><td>cell</td></tr>" }.joined()
        for spacer in stride(from: 760, through: 880, by: 12) {
            let html = """
            <html><head>\(css)</head><body><main>
            <div style="height:\(spacer)px"></div>
            <div class="block"><h3>BLOCK-HEADING</h3>
            <table class="data-table"><thead><tr><th>HEAD-CELL</th><th>x</th></tr></thead>
            <tbody>\(rows)</tbody></table></div></main></body></html>
            """
            let doc = try await exportedDocument(html, name: "heading-\(spacer).pdf")
            let page = try XCTUnwrap(
                (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }
                    .first { $0.contains("BLOCK-HEADING") })
            XCTAssertTrue(page.contains("HEAD-CELL") && page.contains("row-1"),
                          "the block was split after its heading (spacer \(spacer))")
        }
    }

    /// Backgrounds print: the report's bars and severity pills are background colours.
    func testBackgroundColoursPrint() async throws {
        let html = """
        <html><body style="margin:0"><div style="background:#ff0000;height:300px">\
        </div></body></html>
        """
        let doc = try await exportedDocument(html, name: "background.pdf")
        let page = try XCTUnwrap(doc.page(at: 0))
        let image = page.thumbnail(of: CGSize(width: 612, height: 792), for: .mediaBox)
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init))
        // A point inside the div: below the half-inch top margin, in the middle of the page.
        let x = bitmap.pixelsWide / 2
        let y = bitmap.pixelsHigh * 150 / 792
        let colour = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(colour.redComponent, 0.8)
        XCTAssertLessThan(colour.greenComponent, 0.3, "the background did not print")
    }
}
