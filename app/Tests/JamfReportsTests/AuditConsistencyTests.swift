import Foundation
import XCTest
@testable import JamfReports

/// Visual review 2026-10-04, Health Audit:
/// - the summary tile added commands, policies, groups and devices into one "Affected" figure;
/// - the stale finding used jamf-cli's 14 days while the app uses `thresholds.stale_device_days`;
/// - "Failed MDM commands" read CRITICAL with 6359 (commands) beside Command health's WARNING
///   with 217 (devices) for the same condition.
final class AuditConsistencyTests: XCTestCase {

    private func finding(
        _ name: String, _ affected: Int, severity: String, category: String = "compliance"
    ) -> AuditFinding {
        AuditFinding(
            name: name, affected: affected, category: category,
            recommendation: "r", severity: severity)
    }

    private func scan(failedDevices: Int) -> MDMCommandHealthService.Snapshot {
        let records = (0..<failedDevices).map {
            MDMCommandHealthRecord(
                deviceId: "\($0)", name: "d\($0)", failedCount: 3, pendingCount: 0,
                failedCommands: ["X"], oldestPendingDays: nil)
        }
        return .init(records: records, isDetected: true, readFailed: false,
                     snapshotDate: nil, sourceDates: [:])
    }

    // MARK: - Summary tile

    func testTheSummaryTileCountsFindingsNotAMixOfUnits() {
        let rows = [
            finding("Failed MDM commands", 6359, severity: "CRITICAL"),
            finding("Policies with no scope", 377, severity: "WARNING"),
            finding("Empty smart groups", 25, severity: "INFO"),
            finding("Unencrypted devices", 0, severity: "OK"),
        ]
        XCTAssertEqual(rows.openCount, 3, "an OK finding needs no look")
        XCTAssertEqual([AuditFinding]().openCount, 0)
    }

    // MARK: - Stale threshold

    func testAuditPassesTheConfiguredStaleDays() {
        XCTAssertEqual(
            ReportEngine.auditArguments(profile: "p", staleDays: 30),
            ["-p", "p", "pro", "audit", "--output", "json", "--no-input", "--days", "30"])
        XCTAssertEqual(
            ReportEngine.auditArguments(profile: "p", staleDays: 45, category: "security")
                .suffix(4),
            ["--days", "45", "--checks", "security"])
        XCTAssertEqual(
            ReportEngine.auditArguments(profile: "p", staleDays: 0).suffix(2), ["--days", "1"],
            "a threshold below 1 would flag every Mac")
    }

    func testCollectRunsTheSameAuditCommand() throws {
        let row = try XCTUnwrap(
            ReportEngine.collectCommandMatrix(profile: "p", specNames: true, staleDays: 21)
                .first { $0.kind == "audit" })
        XCTAssertEqual(row.args, ReportEngine.auditArguments(profile: "p", staleDays: 21))
    }

    func testTheAuditReadsStaleDaysFromTheWorkspaceConfig() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JRC-AuditDays-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("acme", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }

        XCTAssertEqual(CLIBridge.auditStaleDays(profile: "acme"), 30, "no config: the default")
        try Data("thresholds:\n  stale_device_days: 45\n".utf8)
            .write(to: workspace.appendingPathComponent("config.yaml"))
        XCTAssertEqual(CLIBridge.auditStaleDays(profile: "acme"), 45)
    }

    // MARK: - Failed MDM commands

    func testAScannedWorkspaceDropsTheCumulativeCommandRowAndKeepsItsCount() {
        let rows = [
            finding("Stale check-in (>30 days)", 154, severity: "WARNING"),
            finding("Failed MDM commands", 6359, severity: "CRITICAL"),
            finding("Unencrypted devices", 9, severity: "CRITICAL", category: "security"),
        ]
        let split = withoutSupersededRows(rows, commandHealthDetected: true)
        XCTAssertEqual(split.shown.map(\.name),
                       ["Stale check-in (>30 days)", "Unencrypted devices"])
        XCTAssertEqual(split.failedCommandTotal, 6359)
    }

    func testWithoutAScanTheAuditRowStays() {
        let rows = [finding("Failed MDM commands", 6359, severity: "CRITICAL")]
        let split = withoutSupersededRows(rows, commandHealthDetected: false)
        XCTAssertEqual(split.shown.map(\.name), ["Failed MDM commands"])
        XCTAssertNil(split.failedCommandTotal)
    }

    /// One finding for the condition, in devices, at one severity, carrying the command count.
    func testFailedCommandsAppearOnceAsDevicesWithTheirCommandCount() throws {
        let audit = [finding("Failed MDM commands", 6359, severity: "CRITICAL")]
        let snapshot = scan(failedDevices: 217)
        let split = withoutSupersededRows(audit, commandHealthDetected: snapshot.isDetected)
        let command = commandHealthFindings(snapshot, failedCommandTotal: split.failedCommandTotal)

        let all = split.shown + command
        let failures = all.filter { $0.name.lowercased().contains("failed mdm commands") }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.affected, 217)
        XCTAssertEqual(failures.first?.severity, "WARNING")
        XCTAssertTrue(
            try XCTUnwrap(failures.first).recommendation.contains("6359 failed commands in total"))
    }

    func testTheCommandNoteIsAbsentWithoutAnAuditRow() throws {
        let command = commandHealthFindings(scan(failedDevices: 2))
        XCTAssertFalse(try XCTUnwrap(command.first).recommendation.contains("in total"))
    }
}
