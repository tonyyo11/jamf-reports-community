import XCTest
@testable import JamfReports

/// How the collect loop copes with what jamf-cli 1.24+ actually prints.
///
/// Both cases here came from a live production run, not from imagination:
/// `--output json` is documented to emit JSON and nothing else, and in two
/// places it does not.
final class JamfCLIOutputToleranceTests: XCTestCase {

    // MARK: - Decorative text ahead of the payload

    /// `pro report patch-status --scan-failures --output json` prints a section
    /// header before the array. That made the entire snapshot unparseable and
    /// silently dropped the Patch Failures sheet on a 134-title tenant.
    func testSectionHeaderBeforeArrayIsStripped() throws {
        let raw = Data("── Patch Title Compliance ──\n[{\"id\":\"1\"}]".utf8)
        let payload = try XCTUnwrap(ReportEngine.jsonPayload(from: raw))
        let decoded = try JSONSerialization.jsonObject(with: payload) as? [[String: Any]]
        XCTAssertEqual(decoded?.count, 1)
        XCTAssertTrue(ReportEngine.isJSONSnapshot(raw))
    }

    func testHeaderBeforeObjectIsStripped() throws {
        let raw = Data("Fetching things...\n{\"total\":3}".utf8)
        let payload = try XCTUnwrap(ReportEngine.jsonPayload(from: raw))
        XCTAssertEqual(String(decoding: payload, as: UTF8.self), "{\"total\":3}")
    }

    /// Clean output must pass through byte-identical — the repair only applies
    /// when there is something to repair.
    func testCleanJSONIsUntouched() throws {
        let raw = Data("[{\"id\":\"1\"}]".utf8)
        XCTAssertEqual(ReportEngine.jsonPayload(from: raw), raw)
    }

    /// Only a PREFIX is forgiven. Cobra help text, a truncated payload, or
    /// anything else that still will not parse must stay rejected — that guard
    /// exists because a renamed command once filled a snapshot with help text.
    func testGenuinelyBrokenOutputIsStillRejected() {
        XCTAssertNil(ReportEngine.jsonPayload(from: Data("Usage:\n  jamf-cli pro report".utf8)))
        XCTAssertNil(ReportEngine.jsonPayload(from: Data("[{\"id\":\"1\"".utf8)), "truncated")
        XCTAssertNil(ReportEngine.jsonPayload(from: Data("no json at all here".utf8)))
    }

    /// A brace inside leading prose must not be mistaken for the payload start.
    func testLeadingProseContainingABraceDoesNotFalselySalvage() {
        XCTAssertNil(
            ReportEngine.jsonPayload(from: Data("warning: use {--select} to narrow\n".utf8))
        )
    }

    // MARK: - Surfacing jamf-cli's own reason

    /// `pro report security` began hard-failing with exit 2 because it demands
    /// Jamf Security Cloud credentials — a different product. "exit 2" alone
    /// sends the operator hunting; jamf-cli already said what was wrong.
    func testErrorMessageIsExtracted() {
        let raw = Data("""
        {"error":"usage","exitCode":2,"exitCodeName":"usage",
         "message":"no Jamf Security Cloud credentials configured: run 'jamf-cli security setup'"}
        """.utf8)
        let message = ReportEngine.jamfCLIErrorMessage(in: raw)
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("Security Cloud") == true)
    }

    func testMissingOrEmptyMessageYieldsNil() {
        XCTAssertNil(ReportEngine.jamfCLIErrorMessage(in: Data("{\"error\":\"usage\"}".utf8)))
        XCTAssertNil(ReportEngine.jamfCLIErrorMessage(in: Data("{\"message\":\"   \"}".utf8)))
        XCTAssertNil(ReportEngine.jamfCLIErrorMessage(in: Data("[{\"id\":1}]".utf8)))
        XCTAssertNil(ReportEngine.jamfCLIErrorMessage(in: Data("not json".utf8)))
    }

    /// One bad call must not flood a run log.
    func testLongMessageIsTruncated() {
        let long = String(repeating: "x", count: 900)
        let raw = Data("{\"message\":\"\(long)\"}".utf8)
        let message = ReportEngine.jamfCLIErrorMessage(in: raw, limit: 100)
        XCTAssertEqual(message?.count, 101, "100 characters plus the ellipsis")
    }
}
