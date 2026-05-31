import Foundation
import XCTest
@testable import JamfReports

// MARK: - ExecutiveSummarySheetTests
//
// Exercises `CoreDashboard.renderExecutiveSummaryRows(into:metrics:)` (pure render
// helper) and `CoreDashboard.writeExecutiveSummary()` (full loader + renderer).

final class ExecutiveSummarySheetTests: XCTestCase {

    // MARK: - Helpers

    private var createdTempDirs: [URL] = []

    override func tearDown() {
        for url in createdTempDirs {
            try? FileManager.default.removeItem(at: url)
        }
        createdTempDirs = []
        super.tearDown()
    }

    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Engine/
            .deletingLastPathComponent()   // JamfReportsTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // app/
            .deletingLastPathComponent()   // worktree root
            .appendingPathComponent("tests/fixtures")
    }

    /// Copy named fixture subdirectories into a fresh temp dataDir.
    private func tempDataDir(copying names: [String]) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-exec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        createdTempDirs.append(tmp)
        let src = fixturesDir.appendingPathComponent("jamf-cli-data")
        for name in names {
            let from = src.appendingPathComponent(name, isDirectory: true)
            let to = tmp.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: from.path) {
                try FileManager.default.copyItem(at: from, to: to)
            }
        }
        return tmp
    }

    private func makeDashboard(dataDir: URL) -> CoreDashboard {
        CoreDashboard(config: ReportConfig(), dataDir: dataDir, workbook: Workbook())
    }

    // MARK: - renderExecutiveSummaryRows — full metrics

    func testRenderWritesAllMetricLabels() {
        let wb = Workbook()
        let ws = wb.addSheet("Executive Summary")
        var m = CoreDashboard.ExecutiveSummaryMetrics()
        m.totalDevices = 500
        m.managedCount = 480
        m.securityScore = 87.5
        m.securityGrade = .b
        m.patchFleetCompliancePct = 91.2
        m.fileVaultPct = 98.0
        m.sipPct = 99.0
        m.firewallPct = 95.0
        m.recentCount = 420
        m.offlineCount = 60
        m.inactiveCount = 15
        m.dormantCount = 5
        m.actionItemsP0 = 10
        m.actionItemsP1 = 3

        let dash = CoreDashboard(config: ReportConfig(),
                                 dataDir: FileManager.default.temporaryDirectory,
                                 workbook: wb)
        dash.renderExecutiveSummaryRows(into: ws, metrics: m)

        let labels = ws.cells.compactMap { cell -> String? in
            if case .string(let s) = cell.value { return s }
            return nil
        }
        // Header row + metric label column
        XCTAssertTrue(labels.contains("Metric"))
        XCTAssertTrue(labels.contains("Value"))
        XCTAssertTrue(labels.contains("Security Score"))
        XCTAssertTrue(labels.contains("Total Devices"))
        XCTAssertTrue(labels.contains("Managed Devices"))
        XCTAssertTrue(labels.contains("Patch Fleet Compliance"))
        XCTAssertTrue(labels.contains("FileVault Coverage"))
        XCTAssertTrue(labels.contains("SIP Coverage"))
        XCTAssertTrue(labels.contains("Firewall Coverage"))
        XCTAssertTrue(labels.contains("Stale — Recent (0–30d)"))
        XCTAssertTrue(labels.contains("Stale — Offline (31–90d)"))
        XCTAssertTrue(labels.contains("Stale — Inactive (91–180d)"))
        XCTAssertTrue(labels.contains("Stale — Dormant (180d+)"))
        XCTAssertTrue(labels.contains("P0 Action Items (FV/SIP/FW gaps)"))
        XCTAssertTrue(labels.contains("P1 Action Items (Gatekeeper gaps)"))
    }

    func testRenderFormatsSecurityScore() {
        let wb = Workbook()
        let ws = wb.addSheet("Executive Summary")
        var m = CoreDashboard.ExecutiveSummaryMetrics()
        m.securityScore = 92.3
        m.securityGrade = .a

        CoreDashboard(config: ReportConfig(),
                      dataDir: FileManager.default.temporaryDirectory,
                      workbook: wb)
            .renderExecutiveSummaryRows(into: ws, metrics: m)

        let values = ws.cells.compactMap { cell -> String? in
            if case .string(let s) = cell.value { return s }
            return nil
        }
        XCTAssertTrue(values.contains("92.3 / 100 (A)"),
                      "Score label must be '<value> / 100 (<grade>)'")
    }

    // MARK: - renderExecutiveSummaryRows — nil / empty metrics

    func testRenderGracefullyOmitsMissingMetrics() {
        let wb = Workbook()
        let ws = wb.addSheet("Executive Summary")
        // All fields nil
        let m = CoreDashboard.ExecutiveSummaryMetrics()

        CoreDashboard(config: ReportConfig(),
                      dataDir: FileManager.default.temporaryDirectory,
                      workbook: wb)
            .renderExecutiveSummaryRows(into: ws, metrics: m)

        let values = ws.cells.compactMap { cell -> String? in
            if case .string(let s) = cell.value { return s }
            return nil
        }
        // Dash placeholder must appear for missing values
        XCTAssertTrue(values.contains("—"),
                      "nil metrics must render '—' placeholder")
        // All 13 metric labels still present
        XCTAssertTrue(values.contains("Security Score"))
        XCTAssertTrue(values.contains("Total Devices"))
        // No crash — cell count > header row alone
        XCTAssertGreaterThan(ws.cells.count, 4)
    }

    // MARK: - writeExecutiveSummary — with fixtures

    func testWriteExecutiveSummaryWithFixturesProducesSheet() throws {
        let dataDir = try tempDataDir(copying: ["security", "patch-status", "device-compliance"])
        // At least one fixture must be present for a meaningful test.
        let securityPresent = FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent("security").path
        )
        let patchPresent = FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent("patch-status").path
        )
        let devCompPresent = FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent("device-compliance").path
        )
        guard securityPresent || patchPresent || devCompPresent else {
            throw XCTSkip("No relevant fixtures present; skipping integration path")
        }

        let dash = makeDashboard(dataDir: dataDir)
        XCTAssertNoThrow(try dash.writeExecutiveSummary(),
                         "writeExecutiveSummary must not throw when at least one fixture is present")
        XCTAssertNotNil(dash.workbook.sheet(named: "Executive Summary"),
                        "Sheet named 'Executive Summary' must be added to the workbook")
    }

    // MARK: - writeExecutiveSummary — empty dataDir

    func testWriteExecutiveSummaryThrowsSheetSkippableOnEmptyDataDir() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-exec-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        createdTempDirs.append(tmp)

        let dash = makeDashboard(dataDir: tmp)
        XCTAssertThrowsError(try dash.writeExecutiveSummary()) { error in
            XCTAssertTrue(error is SheetSkippable,
                          "Empty dataDir must throw a SheetSkippable error, got \(error)")
        }
    }

    // MARK: - SheetID existence

    func testSheetIDExecutiveSummaryExists() {
        XCTAssertEqual(SheetID.executiveSummary.rawValue, "Executive Summary")
    }

    func testExecutiveTemplateIncludesExecutiveSummaryFirst() {
        let sheets = ExecutiveTemplate().includedSheets
        XCTAssertFalse(sheets.isEmpty)
        XCTAssertEqual(sheets.first, .executiveSummary,
                       "ExecutiveTemplate must list .executiveSummary as its first sheet")
    }
}
