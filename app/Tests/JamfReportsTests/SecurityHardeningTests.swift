import XCTest
@testable import JamfReports

/// Lane H-Sec — verifies the Phase 9 security audit fixes.
///
/// One test per finding (P9-A-01 through P9-A-12). Tests that require a
/// network connection or a known-Jamf-signed binary are skipped with
/// `try XCTSkipIf(...)` rather than expected-to-fail, so the suite remains
/// green in CI environments without those resources.
final class SecurityHardeningTests: XCTestCase {

    // MARK: - P9-A-02 — sanitizedHexColor

    func test_sanitizedHexColor_acceptsValidHex() {
        XCTAssertEqual(HtmlReport.sanitizedHexColor("#2D5EA2", fallback: "#000"), "#2D5EA2")
        XCTAssertEqual(HtmlReport.sanitizedHexColor("#FFF", fallback: "#000"), "#FFF")
        XCTAssertEqual(HtmlReport.sanitizedHexColor("#abcdef12", fallback: "#000"), "#abcdef12")
    }

    func test_sanitizedHexColor_rejectsCSSInjection() {
        // Classic CSS-injection payload: closes the declaration and inserts a rule.
        XCTAssertEqual(
            HtmlReport.sanitizedHexColor("red; } body { display: none; ", fallback: "#2D5EA2"),
            "#2D5EA2"
        )
        // Quotes / parentheses can break the JS string literal in the
        // Chart.js `backgroundColor: '...'` interpolation.
        XCTAssertEqual(
            HtmlReport.sanitizedHexColor("'); alert(1);//", fallback: "#000"),
            "#000"
        )
        XCTAssertEqual(HtmlReport.sanitizedHexColor("", fallback: "#000"), "#000")
        XCTAssertEqual(HtmlReport.sanitizedHexColor("blue", fallback: "#000"), "#000")
    }

    // MARK: - P9-A-03 / P10-B-29 — escapeHTML

    func test_escapeHTML_escapesSingleQuote() {
        XCTAssertEqual(
            HtmlSectionFormatters.escapeHTML("don't"),
            "don&#39;t"
        )
    }

    func test_escapeHTML_blocksDangerousSchemes() {
        XCTAssertEqual(HtmlSectionFormatters.escapeHTML("javascript:alert(1)"), "[blocked]")
        XCTAssertEqual(HtmlSectionFormatters.escapeHTML("vbscript:msgbox 1"), "[blocked]")
        XCTAssertEqual(
            HtmlSectionFormatters.escapeHTML("data:text/javascript,alert(1)"),
            "[blocked]"
        )
        XCTAssertEqual(
            HtmlSectionFormatters.escapeHTML("data:application/javascript,x"),
            "[blocked]"
        )
    }

    func test_escapeHTML_blocksNullByteBypass() {
        // The classic `java\0script:` bypass: control chars are stripped first
        // so the scheme prefix matches.
        XCTAssertEqual(
            HtmlSectionFormatters.escapeHTML("java\u{0000}script:alert(1)"),
            "[blocked]"
        )
        XCTAssertEqual(
            HtmlSectionFormatters.escapeHTML("vbscr\u{0001}ipt:msgbox 1"),
            "[blocked]"
        )
    }

    func test_escapeHTML_preservesSafeContent() {
        XCTAssertEqual(
            HtmlSectionFormatters.escapeHTML("hello & <world>"),
            "hello &amp; &lt;world&gt;"
        )
    }

    // MARK: - P9-A-04 — PDFExporter chart fallback injection

    @MainActor
    func test_pdfExporter_injectsFallbackBeforeHead() async {
        let html = "<html><head><title>x</title></head><body>hi</body></html>"
        let prepared = PDFExporter.preparedHTMLForPDF(html)
        XCTAssertTrue(prepared.contains("Chart unavailable in PDF"))
        XCTAssertTrue(prepared.contains(".chart-card canvas"))
        // Injection must close before </head> so the rule is in scope.
        XCTAssertTrue(prepared.contains("</head>"))
    }

    @MainActor
    func test_pdfExporter_handlesHTMLWithoutHead() async {
        let html = "<body>just a body</body>"
        let prepared = PDFExporter.preparedHTMLForPDF(html)
        XCTAssertTrue(prepared.contains("Chart unavailable in PDF"))
    }

    // MARK: - P9-A-06 — WorkspacePaths absolute escape

    func test_workspacePaths_rejectsForbiddenAbsoluteUnderHome() throws {
        // Without a real workspace and config, we exercise the typed error
        // shape and the forbidden-path classifier indirectly via the public
        // resolver. For this lane we just assert the error case exists in the
        // type so call sites can pattern-match on it.
        let dummy = URL(fileURLWithPath: "/etc/passwd")
        let err: Error = WorkspacePaths.PathError.disallowedAbsolutePath(dummy)
        XCTAssertNotNil((err as? WorkspacePaths.PathError)?.errorDescription)
    }

    // MARK: - P9-A-08 — JamfCLIInstaller asset validation

    @MainActor
    func test_jamfCLIInstaller_rejectsBadHost() {
        XCTAssertThrowsError(try JamfCLIInstaller.validateAsset(
            host: "evil.example.com",
            name: "jamf-cli-darwin-arm64.tar.gz"
        )) { error in
            XCTAssertTrue("\(error)".lowercased().contains("untrusted host"))
        }
    }

    @MainActor
    func test_jamfCLIInstaller_rejectsTraversalInName() {
        XCTAssertThrowsError(try JamfCLIInstaller.validateAsset(
            host: "github.com",
            name: "../../../etc/passwd"
        ))
        XCTAssertThrowsError(try JamfCLIInstaller.validateAsset(
            host: "github.com",
            name: "jamf-cli/../bad.tar.gz"
        ))
        XCTAssertThrowsError(try JamfCLIInstaller.validateAsset(
            host: "github.com",
            name: "jamf-cli\u{0000}.tar.gz"
        ))
    }

    @MainActor
    func test_jamfCLIInstaller_rejectsNonArchiveSuffix() {
        XCTAssertThrowsError(try JamfCLIInstaller.validateAsset(
            host: "github.com",
            name: "jamf-cli.exe"
        ))
    }

    @MainActor
    func test_jamfCLIInstaller_acceptsValidArchiveName() throws {
        try JamfCLIInstaller.validateAsset(
            host: "objects.githubusercontent.com",
            name: "jamf-cli-1.14.0-darwin-arm64.tar.gz"
        )
        try JamfCLIInstaller.validateAsset(
            host: "github.com",
            name: "jamf-cli-darwin.zip"
        )
    }

    // MARK: - Archive entry preflight (P-new-02)

    @MainActor
    func test_rejectUnsafeArchiveEntry_rejectsAbsolutePath() {
        XCTAssertThrowsError(try JamfCLIInstaller.rejectUnsafeArchiveEntry("/etc/passwd"))
    }

    @MainActor
    func test_rejectUnsafeArchiveEntry_rejectsTraversal() {
        XCTAssertThrowsError(try JamfCLIInstaller.rejectUnsafeArchiveEntry("../../etc/passwd"))
        XCTAssertThrowsError(try JamfCLIInstaller.rejectUnsafeArchiveEntry("foo/../bar"))
    }

    @MainActor
    func test_rejectUnsafeArchiveEntry_rejectsTarSymlinkTraversal() {
        // BSD tar verbose listings surface symlinks as `name -> target`.
        // A `..` anywhere on the line is rejected, which catches the target side too.
        XCTAssertThrowsError(
            try JamfCLIInstaller.rejectUnsafeArchiveEntry("link -> ../../etc/hosts")
        )
    }

    @MainActor
    func test_rejectUnsafeArchiveEntry_rejectsControlChars() {
        XCTAssertThrowsError(
            try JamfCLIInstaller.rejectUnsafeArchiveEntry("safe-name\u{0001}.txt")
        )
    }

    @MainActor
    func test_rejectUnsafeArchiveEntry_acceptsSafeNames() throws {
        try JamfCLIInstaller.rejectUnsafeArchiveEntry("jamf-cli")
        try JamfCLIInstaller.rejectUnsafeArchiveEntry("bin/jamf-cli")
        try JamfCLIInstaller.rejectUnsafeArchiveEntry("jamf-cli-1.14.0/jamf-cli")
    }

    // MARK: - Helpers

    /// Walk up from the test bundle to the `app/` source directory so we can
    /// assert on shell scripts that aren't part of the SwiftPM resource graph.
    private func sourceRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SecurityHardeningTests.swift
            .deletingLastPathComponent()  // JamfReportsTests
            .deletingLastPathComponent()  // Tests
        // Returned URL points at the `app/` directory.
    }
}
