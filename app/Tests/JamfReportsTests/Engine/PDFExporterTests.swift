import XCTest
@testable import JamfReports

// MARK: - PDFExporterTests

/// Tests for PDFExporter HTML-to-PDF conversion via WKWebView.createPDF.
///
/// All tests run on the main actor because WKWebView is main-thread-only.
/// A 15-second test timeout guards against WKWebView load hangs (e.g., CDN
/// unreachable in CI — Chart.js is referenced from the full HTML template but
/// these tests use minimal HTML that loads instantly).
@MainActor
final class PDFExporterTests: XCTestCase {

    private var outputDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFExporterTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: outputDir)
        try await super.tearDown()
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
}
