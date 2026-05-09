import Foundation
import XCTest
@testable import JamfReports

// MARK: - ExceptionsConfigTests
//
// Verifies the Phase 6 `exceptions:` config block and the migrated
// `buildExceptionList` HTML renderer.

final class ExceptionsConfigTests: XCTestCase {

    // MARK: - Helpers

    private func makeReport(config: ReportConfig) -> HtmlReport {
        HtmlReport(config: config, dataDir: URL(fileURLWithPath: "/tmp/nonexistent"))
    }

    private func configWithExceptions(_ yaml: String) throws -> ReportConfig {
        try ConfigLoader.loadFromString(yaml)
    }

    // MARK: - YAML round-trip

    func testExceptionsDecodesTwoEntries() throws {
        let yaml = """
        exceptions:
          - id: "MSCP-001"
            description: "Password policy waiver"
            signed_off_by: "Jane Smith, ISSO"
            signed_off_date: "2026-04-01"
            expires_date: "2026-10-01"
            linked_finding: "audit.password_min_length"
          - id: "MSCP-002"
            description: "Screen lock waiver"
            signed_off_by: "John Doe"
            signed_off_date: "2026-03-15"
        """
        let config = try configWithExceptions(yaml)
        let exceptions = config.exceptions ?? []
        XCTAssertEqual(exceptions.count, 2)
        XCTAssertEqual(exceptions[0].id, "MSCP-001")
        XCTAssertEqual(exceptions[0].description, "Password policy waiver")
        XCTAssertEqual(exceptions[0].signedOffBy, "Jane Smith, ISSO")
        XCTAssertEqual(exceptions[0].signedOffDate, "2026-04-01")
        XCTAssertEqual(exceptions[0].expiresDate, "2026-10-01")
        XCTAssertEqual(exceptions[0].linkedFinding, "audit.password_min_length")
        XCTAssertEqual(exceptions[1].id, "MSCP-002")
        XCTAssertNil(exceptions[1].expiresDate, "Optional expires_date should be nil when absent")
        XCTAssertNil(exceptions[1].linkedFinding, "Optional linked_finding should be nil when absent")
    }

    func testExceptionsAbsentDecodesAsNilOrEmpty() throws {
        let yaml = """
        columns:
          computer_name: "Computer Name"
        """
        let config = try configWithExceptions(yaml)
        let exceptions = config.exceptions ?? []
        XCTAssertTrue(exceptions.isEmpty, "Absent exceptions: block must decode as empty")
    }

    // MARK: - Renderer with non-empty exceptions block

    func testRendererWithExceptionsProducesTableWithIDAndDescription() throws {
        let yaml = """
        exceptions:
          - id: "EX-001"
            description: "Example waiver"
            signed_off_by: "Alice"
            signed_off_date: "2026-01-01"
        """
        let config = try configWithExceptions(yaml)
        let html = makeReport(config: config).buildExceptionList()
        XCTAssertTrue(html.contains("EX-001"), "Exception ID must appear in rendered HTML")
        XCTAssertTrue(html.contains("Example waiver"), "Exception description must appear in rendered HTML")
        XCTAssertTrue(html.contains("Alice"), "Signed-off-by must appear in rendered HTML")
    }

    func testRendererEscapesXSSInExceptionFields() throws {
        let xss = "<script>alert(1)</script>"
        let yaml = """
        exceptions:
          - id: "\(xss)"
            description: "Safe"
            signed_off_by: "Bob"
            signed_off_date: "2026-01-01"
        """
        let config = try configWithExceptions(yaml)
        let html = makeReport(config: config).buildExceptionList()
        XCTAssertFalse(html.contains("<script>"), "XSS in exception id must be escaped")
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    // MARK: - Renderer fallback to custom_eas with tip

    func testRendererFallsBackToCustomEAsWhenExceptionsEmpty() throws {
        let yaml = """
        custom_eas:
          - name: "FileVault Status"
            column: "FileVault 2 - Status"
            type: boolean
            true_value: "Encrypted"
        """
        let config = try configWithExceptions(yaml)
        let html = makeReport(config: config).buildExceptionList()
        XCTAssertTrue(
            html.contains("FileVault Status"),
            "Fallback renderer must include custom_ea name"
        )
        XCTAssertTrue(
            html.contains("empty-hint"),
            "Fallback renderer must include migration tip paragraph"
        )
        XCTAssertTrue(
            html.contains("exceptions:"),
            "Migration tip must mention exceptions: key"
        )
    }

    func testRendererShowsTipInFallbackMode() throws {
        let yaml = """
        custom_eas:
          - name: "SysTrack"
            column: "SysTrack Status"
            type: boolean
            true_value: "Installed"
        """
        let config = try configWithExceptions(yaml)
        let html = makeReport(config: config).buildExceptionList()
        XCTAssertTrue(html.contains("config.yaml"), "Tip must reference config.yaml")
    }

    // MARK: - Empty state when both are absent

    func testRendererEmptyStateWhenBothAbsent() throws {
        let config = try configWithExceptions("columns:\n  computer_name: Name")
        let html = makeReport(config: config).buildExceptionList()
        XCTAssertTrue(html.contains("exception-list"), "Section ID must be present")
        XCTAssertTrue(
            html.contains("exceptions:"),
            "Empty state must recommend exceptions: block"
        )
    }

    // MARK: - Expired row highlighting

    func testExpiredRowContainsExpiredPill() throws {
        let yaml = """
        exceptions:
          - id: "OLD-001"
            description: "Long-expired waiver"
            signed_off_by: "Charlie"
            signed_off_date: "2019-06-01"
            expires_date: "2020-01-01"
        """
        let config = try configWithExceptions(yaml)
        let html = makeReport(config: config).buildExceptionList()
        XCTAssertTrue(
            html.contains("Expired") || html.contains("sev-error"),
            "Row with past expires_date must contain Expired pill or sev-error class"
        )
    }

    func testNonExpiredRowDoesNotContainExpiredPill() throws {
        // Use a far-future date to avoid flakiness.
        let yaml = """
        exceptions:
          - id: "FUTURE-001"
            description: "Future waiver"
            signed_off_by: "Dana"
            signed_off_date: "2025-01-01"
            expires_date: "2099-12-31"
        """
        let config = try configWithExceptions(yaml)
        let html = makeReport(config: config).buildExceptionList()
        XCTAssertFalse(
            html.contains("sev-error"),
            "Row with future expires_date must not contain sev-error class"
        )
    }

    func testExceptionWithInvalidDateFormatIsNotFlaggedExpired() throws {
        // Non-ISO date stored verbatim; must not trigger expired logic.
        let yaml = """
        exceptions:
          - id: "BAD-DATE"
            description: "Non-ISO date"
            signed_off_by: "Eve"
            signed_off_date: "April 2026"
            expires_date: "not-a-date"
        """
        let config = try configWithExceptions(yaml)
        let html = makeReport(config: config).buildExceptionList()
        XCTAssertFalse(
            html.contains("sev-error"),
            "Non-ISO expires_date must not trigger Expired pill"
        )
    }
}
