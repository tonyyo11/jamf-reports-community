import XCTest
import SwiftUI
@testable import JamfReports

/// Tests for the PatchStatusService and PatchView. Confirms the service can
/// decode jamf-cli patch-status JSON shapes and compute aggregate metrics,
/// and that the view instantiates without crashing in both demo and live modes.
@MainActor
final class PatchStatusServiceTests: XCTestCase {

    func testPatchViewInstantiatesInDemoMode() throws {
        let workspace = WorkspaceStore()
        workspace.profile = "test"
        workspace.demoMode = true

        _ = PatchView().environment(workspace)
    }

    func testPatchViewInstantiatesOutsideDemoMode() throws {
        let workspace = WorkspaceStore()
        workspace.profile = "test"
        workspace.demoMode = false

        _ = PatchView().environment(workspace)
    }

    // MARK: - Service decode parity

    func testPatchStatusServiceDecodeParity() throws {
        let titlesJSON = """
        [
          {"title": "Firefox", "id": "123", "on_latest": 80, "on_other": 20,
           "total": 100, "latest": "132.0", "compliance_pct": "80%"},
          {"title": "Chrome", "id": "124", "on_latest": 45, "on_other": 55,
           "total": 100, "latest": "131.0", "compliance_pct": "45%"},
          {"title": "Office", "id": "125", "on_latest": 95, "on_other": 5,
           "total": 100, "latest": "16.91", "compliance_pct": "95%"}
        ]
        """

        let failuresJSON = """
        [
          {"policy": "Firefox", "policy_id": "123", "device": "Mac-001",
           "device_id": "1001", "status_date": "2025-01-08", "attempt": 2,
           "last_action": "Failed", "serial": "ABC123", "os_version": "15.4.1",
           "username": "jdoe"},
          {"policy": "Chrome", "policy_id": "124", "device": "Mac-002",
           "device_id": "1002", "status_date": "2025-01-07", "attempt": 1,
           "last_action": "Retrying", "serial": "XYZ789", "os_version": "14.7.5",
           "username": "asmith"},
          {"policy": "Firefox", "policy_id": "123", "device": "Mac-003",
           "device_id": "1003", "status_date": "2025-01-06", "attempt": 3,
           "last_action": "Download Failed", "serial": "DEF456", "os_version": "15.4.1",
           "username": ""}
        ]
        """

        let tmp = FileManager.default.temporaryDirectory
        let titlesURL = tmp.appendingPathComponent("titles-\(UUID().uuidString).json")
        let failuresURL = tmp.appendingPathComponent("failures-\(UUID().uuidString).json")

        try Data(titlesJSON.utf8).write(to: titlesURL)
        try Data(failuresJSON.utf8).write(to: failuresURL)
        defer {
            try? FileManager.default.removeItem(at: titlesURL)
            try? FileManager.default.removeItem(at: failuresURL)
        }

        let snapshot = try XCTUnwrap(PatchStatusService.load(from: titlesURL, failuresURL: failuresURL))

        // Title counts
        XCTAssertEqual(snapshot.totalTitles, 3)
        XCTAssertEqual(snapshot.compliantTitleCount, 1, "Only Office at 95%")
        XCTAssertEqual(snapshot.failingTitleCount, 1, "Only Chrome at 45%")

        // Fleet compliance: weighted average
        // Firefox: 80% × 100 devices = 8000
        // Chrome: 45% × 100 devices = 4500
        // Office: 95% × 100 devices = 9500
        // Total: 22000 / 300 = 73.33%
        XCTAssertEqual(snapshot.fleetCompliancePct, 73.33, accuracy: 0.01)

        // Failure counts
        XCTAssertEqual(snapshot.failures.count, 3)
        XCTAssertEqual(snapshot.devicesWithFailures, 3, "3 unique device IDs")

        let failuresByTitle = snapshot.failuresByTitle
        XCTAssertEqual(failuresByTitle["Firefox"], 2, "2 Firefox failures")
        XCTAssertEqual(failuresByTitle["Chrome"], 1, "1 Chrome failure")
        XCTAssertEqual(failuresByTitle["Office"], nil, "No Office failures")
    }

    func testEmptyInputHandling() throws {
        let emptyTitlesJSON = "[]"
        let emptyFailuresJSON = "[]"

        let tmp = FileManager.default.temporaryDirectory
        let titlesURL = tmp.appendingPathComponent("empty-titles-\(UUID().uuidString).json")
        let failuresURL = tmp.appendingPathComponent("empty-failures-\(UUID().uuidString).json")

        try Data(emptyTitlesJSON.utf8).write(to: titlesURL)
        try Data(emptyFailuresJSON.utf8).write(to: failuresURL)
        defer {
            try? FileManager.default.removeItem(at: titlesURL)
            try? FileManager.default.removeItem(at: failuresURL)
        }

        let snapshot = try XCTUnwrap(PatchStatusService.load(from: titlesURL, failuresURL: failuresURL))

        XCTAssertEqual(snapshot.totalTitles, 0)
        XCTAssertEqual(snapshot.compliantTitleCount, 0)
        XCTAssertEqual(snapshot.failingTitleCount, 0)
        XCTAssertEqual(snapshot.fleetCompliancePct, 0)
        XCTAssertEqual(snapshot.devicesWithFailures, 0)
        XCTAssertTrue(snapshot.failuresByTitle.isEmpty)
    }

    func testCompliancePctParsing() throws {
        // Normal cases
        XCTAssertEqual(PatchStatusService.parseCompliancePct("83%"), 83.0)
        XCTAssertEqual(PatchStatusService.parseCompliancePct("100%"), 100.0)
        XCTAssertEqual(PatchStatusService.parseCompliancePct("0%"), 0.0)
        XCTAssertEqual(PatchStatusService.parseCompliancePct("50"), 50.0)

        // Edge cases
        XCTAssertEqual(PatchStatusService.parseCompliancePct(" 75% "), 75.0)
        XCTAssertEqual(PatchStatusService.parseCompliancePct(""), 0.0)
        XCTAssertEqual(PatchStatusService.parseCompliancePct("invalid"), 0.0)
        XCTAssertEqual(PatchStatusService.parseCompliancePct("N/A"), 0.0)
    }

    // MARK: - Compliance CSV export

    private func sampleRow(
        title: String, latest: String = "1.0",
        onLatest: Int = 5, onOther: Int = 5,
        total: Int = 10, compliancePct: String = "50%"
    ) -> PatchStatusRow {
        PatchStatusRow(
            title: title, id: "id-\(title)", onLatest: onLatest,
            onOther: onOther, total: total, latest: latest,
            compliancePct: compliancePct
        )
    }

    func testComplianceCSVMatchesSheetColumnShape() {
        let rows = [
            sampleRow(title: "Firefox", latest: "132.0", onLatest: 80,
                      onOther: 20, total: 100, compliancePct: "80%"),
            sampleRow(title: "Chrome", latest: "131.0", onLatest: 45,
                      onOther: 55, total: 100, compliancePct: "45%"),
        ]
        let csv = PatchStatusService.complianceCSV(rows)
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)

        // Header matches the engine's "Patch Compliance" sheet columns.
        XCTAssertEqual(String(lines[0]), "Title,Latest,On Latest,On Other,Total,Compliance %")
        // Rows follow input order — same as CoreDashboard.writePatch.
        XCTAssertEqual(String(lines[1]), "Firefox,132.0,80,20,100,80%")
        XCTAssertEqual(String(lines[2]), "Chrome,131.0,45,55,100,45%")
        XCTAssertTrue(csv.hasSuffix("\n"), "CSV should end with a trailing newline")
    }

    func testComplianceCSVQuotesFieldsContainingCommas() {
        let rows = [sampleRow(title: "Acme, Inc. Security Agent", latest: "2.0")]
        let csv = PatchStatusService.complianceCSV(rows)
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(
            String(lines[1]),
            "\"Acme, Inc. Security Agent\",2.0,5,5,10,50%",
            "A title with a comma must be wrapped in double-quotes per RFC 4180"
        )
    }

    func testComplianceCSVEmptyTitlesYieldsHeaderOnly() {
        XCTAssertEqual(
            PatchStatusService.complianceCSV([]),
            PatchStatusService.complianceCSVHeader + "\n"
        )
    }

    func testComplianceCSVNeutralizesFormulaInjection() {
        // Patch titles originate from jamf-cli / Jamf Pro patch definitions;
        // a leading =,+,-,@ must be tab-guarded so opening the CSV in Excel
        // or Numbers treats it as text, not a formula — matching the xlsx path.
        let rows = [
            sampleRow(title: "=HYPERLINK(\"http://evil\",\"x\")", latest: "1.0"),
            sampleRow(title: "@SUM(A1:A9)", latest: "+1+1"),
        ]
        let lines = PatchStatusService.complianceCSV(rows)
            .split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertTrue(String(lines[1]).contains("\t=HYPERLINK"),
                      "A '=' title must be tab-prefixed")
        XCTAssertTrue(String(lines[2]).contains("\t@SUM"),
                      "A '@' title must be tab-prefixed")
        XCTAssertTrue(String(lines[2]).contains("\t+1+1"),
                      "A '+' value in any column must be tab-prefixed")
    }

    func testFailuresOnlyWithoutTitles() throws {
        // Test that we can handle missing failures file gracefully
        let titlesJSON = """
        [
          {"title": "Firefox", "id": "123", "on_latest": 50, "on_other": 50,
           "total": 100, "latest": "132.0", "compliance_pct": "50%"}
        ]
        """

        let tmp = FileManager.default.temporaryDirectory
        let titlesURL = tmp.appendingPathComponent("solo-titles-\(UUID().uuidString).json")

        try Data(titlesJSON.utf8).write(to: titlesURL)
        defer { try? FileManager.default.removeItem(at: titlesURL) }

        // Pass nil for failuresURL
        let snapshot = try XCTUnwrap(PatchStatusService.load(from: titlesURL, failuresURL: nil))

        XCTAssertEqual(snapshot.totalTitles, 1)
        XCTAssertEqual(snapshot.failures.count, 0)
        XCTAssertEqual(snapshot.devicesWithFailures, 0)
        XCTAssertTrue(snapshot.failuresByTitle.isEmpty)
        XCTAssertEqual(snapshot.fleetCompliancePct, 50.0)
    }
}