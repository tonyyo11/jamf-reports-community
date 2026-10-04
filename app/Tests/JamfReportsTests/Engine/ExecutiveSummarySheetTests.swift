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

    private var fixturesDir: URL { TestFixtures.root }

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
            try? TestFixtures.copyDir(from, to: to)
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
        XCTAssertTrue(labels.contains("Recent (0–30d)"))
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

    // MARK: - Security metrics under the policy

    private func metrics(
        _ yaml: String = "", dataDir: URL
    ) throws -> CoreDashboard.ExecutiveSummaryMetrics {
        CoreDashboard.executiveMetrics(
            config: try ConfigLoader.loadFromString(yaml), dataDir: dataDir)
    }

    /// Fixture `security.json` (the dummy tenant's `pro report security`): 101 Macs, FileVault
    /// 100, SIP 1, Firewall 0, Gatekeeper 100; SIP is NOT_COLLECTED on 100 rows. Score = mean
    /// of 99.0, 100 (the one Mac that reported SIP) and 0.0 percent.
    func testExecutiveMetricsOnTheSecurityFixtureCountOnlyMeasuredMacs() throws {
        let dataDir = try tempDataDir(copying: ["security"])
        let m = try metrics(dataDir: dataDir)
        XCTAssertEqual(m.totalDevices, 101)
        XCTAssertEqual(try XCTUnwrap(m.securityScore), 66.3, accuracy: 0.001)
        XCTAssertEqual(m.securityGrade, .d)
        XCTAssertEqual(m.actionItemsP1, 1)
        XCTAssertEqual(m.p0NotReported, 100)
        XCTAssertEqual(m.p1NotReported, 0)
        XCTAssertEqual(try XCTUnwrap(m.fileVaultPct), 99.0, accuracy: 0.05)
    }

    /// Intended change: P0 was `total - FileVault on` (1) under a label that names FileVault,
    /// SIP and Firewall gaps. It counts all three over the Macs that reported: 1 + 0 + 101,
    /// the 100 Macs with SIP NOT_COLLECTED being neither.
    func testActionItemP0CountsFileVaultSipAndFirewallGaps() throws {
        let dataDir = try tempDataDir(copying: ["security"])
        XCTAssertEqual(try metrics(dataDir: dataDir).actionItemsP0, 102)
    }

    func testExecutiveMetricsFollowThePolicy() throws {
        let dataDir = try tempDataDir(copying: ["security"])
        let sip = try metrics("security_policy:\n  controls:\n    sip: warning\n", dataDir: dataDir)
        XCTAssertEqual(sip.actionItemsP0, 1 + 101, "FileVault and Firewall only")
        // (99.01 + 100 + 0) / 3
        XCTAssertEqual(try XCTUnwrap(sip.securityScore), 66.3, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(sip.sipPct), 1.0, accuracy: 0.05, "coverage stays a fact")

        let firewall = try metrics(
            "security_policy:\n  controls:\n    firewall: ignore\n", dataDir: dataDir)
        XCTAssertEqual(firewall.actionItemsP0, 1, "SIP's 100 Macs did not report")
        XCTAssertEqual(try XCTUnwrap(firewall.securityScore), 99.5, accuracy: 0.001)

        let gatekeeper = try metrics(
            "security_policy:\n  controls:\n    gatekeeper: ignore\n", dataDir: dataDir)
        XCTAssertEqual(gatekeeper.actionItemsP1, 0)
    }

    /// The workbook and summary.json count the same: the summary writer's P0, P1 and score
    /// for the fixture are this sheet's (P0 0, P1 0, score 100 here, against 1, 1, 33.3 before).
    func testExecutiveMetricsMatchTheSummaryWriter() throws {
        // The summary writer drops snapshots older than `max_cache_age_hours`, so the fixture
        // goes in under a stamp from an hour ago.
        let dataDir = try tempDataDir(copying: [])
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd'T'HHmmss"
        let securityDir = dataDir.appendingPathComponent("security", isDirectory: true)
        try FileManager.default.createDirectory(at: securityDir, withIntermediateDirectories: true)
        let fixture = fixturesDir.appendingPathComponent("jamf-cli-data/security/security.json")
        try Data(contentsOf: fixture)
            .write(to: securityDir.appendingPathComponent(
                "security_\(stamp.string(from: Date().addingTimeInterval(-3600))).json"))
        let policy = """
        security_policy:
          controls:
            filevault: warning
            sip: warning
            firewall: ignore
            gatekeeper: ignore
        """
        let config = try ConfigLoader.loadFromString(policy)
        let m = CoreDashboard.executiveMetrics(config: config, dataDir: dataDir)
        let summaries = dataDir.appendingPathComponent("summaries", isDirectory: true)
        ReportEngine(config: config, dataDir: dataDir).emitSummaryJSON(summariesDir: summaries)
        let summary = try XCTUnwrap(SummaryJSONParser.parseDirectory(summaries).first)
        XCTAssertEqual(m.actionItemsP0, summary.actionItemsP0)
        XCTAssertEqual(m.actionItemsP1, summary.actionItemsP1)
        XCTAssertEqual(try XCTUnwrap(m.securityScore), try XCTUnwrap(summary.securityScore),
                       accuracy: 0.001)
    }

    /// Ten Macs, FileVault on for seven; the three off are Apple silicon.
    private func hardwareDataDir() throws -> URL {
        func device(_ name: String, _ serial: String, _ fileVault: String) -> [String: Any] {
            ["section": "device", "name": name, "serial": serial, "os_version": "15.4.1",
             "filevault": fileVault, "sip": "ENABLED", "firewall": true,
             "gatekeeper": "APP_STORE"]
        }
        var items: [[String: Any]] = [["section": "summary", "data": [
            "total_devices": 10, "filevault_encrypted": 7, "sip_enabled": 10,
            "firewall_enabled": 10, "gatekeeper_enabled": 10,
        ]]]
        for n in 1...7 { items.append(device("on\(n)", "ON\(n)", "ENCRYPTED")) }
        for n in 1...3 { items.append(device("as\(n)", "AS\(n)", "UNENCRYPTED")) }
        let computers: [[String: Any]] = (1...3).map { n in
            ["general": ["name": "as\(n)"],
             "hardware": ["serialNumber": "AS\(n)", "appleSilicon": true]]
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-exec-hw-\(UUID().uuidString)", isDirectory: true)
        createdTempDirs.append(dir)
        for (kind, object) in [("security", items as Any), ("computers", computers as Any)] {
            let kindDir = dir.appendingPathComponent(kind, isDirectory: true)
            try FileManager.default.createDirectory(at: kindDir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object)
                .write(to: kindDir.appendingPathComponent("\(kind).json"))
        }
        return dir
    }

    func testExecutiveMetricsCountHardwareEncryptedMacsApart() throws {
        let dataDir = try hardwareDataDir()
        let none = try metrics(dataDir: dataDir)
        XCTAssertEqual(none.actionItemsP0, 3)
        XCTAssertEqual(none.fileVaultOffHardwareEncrypted, 0)
        XCTAssertEqual(try XCTUnwrap(none.securityScore), 90.0, accuracy: 0.001)

        let warning = try metrics(
            "security_policy:\n  filevault_off_hardware_encrypted: warning\n", dataDir: dataDir)
        XCTAssertEqual(warning.actionItemsP0, 0)
        XCTAssertEqual(warning.fileVaultOffHardwareEncrypted, 3)
        XCTAssertEqual(try XCTUnwrap(warning.securityScore), 100.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(warning.fileVaultPct), 70.0, accuracy: 0.001, "the fact")

        let ignore = try metrics(
            "security_policy:\n  filevault_off_hardware_encrypted: ignore\n", dataDir: dataDir)
        XCTAssertEqual(ignore.actionItemsP0, 0)
        XCTAssertEqual(ignore.fileVaultOffHardwareEncrypted, 3)
        // FileVault is 7 of the 7 Macs still counted.
        XCTAssertEqual(try XCTUnwrap(ignore.securityScore), 100.0, accuracy: 0.001)
    }

    private func labels(of ws: Worksheet) -> [String] {
        ws.cells.filter { $0.col == 0 }.sorted { $0.row < $1.row }.compactMap {
            if case .string(let s) = $0.value { return s }
            return nil
        }
    }

    func testRenderAddsTheHardwareEncryptedRowAfterFileVaultCoverage() {
        let wb = Workbook()
        let ws = wb.addSheet("Executive Summary")
        var m = CoreDashboard.ExecutiveSummaryMetrics()
        m.fileVaultPct = 70
        m.fileVaultOffHardwareEncrypted = 3
        CoreDashboard(config: ReportConfig(), dataDir: FileManager.default.temporaryDirectory,
                      workbook: wb).renderExecutiveSummaryRows(into: ws, metrics: m)
        let order = labels(of: ws)
        let index = order.firstIndex(of: "FileVault Coverage")
        XCTAssertNotNil(index)
        XCTAssertEqual(index.map { order[$0 + 1] }, "FileVault off, hardware-encrypted")
        let valueRow = ws.cells.first {
            if case .string("FileVault off, hardware-encrypted") = $0.value { return true }
            return false
        }?.row
        let value = ws.cells.first { $0.row == valueRow && $0.col == 1 }
        if case .string(let text)? = value?.value { XCTAssertEqual(text, "3") } else {
            XCTFail("the row has no value")
        }
    }

    func testRenderLeavesOutTheHardwareEncryptedRowWithoutMacsToName() {
        for count in [nil, 0] as [Int?] {
            let wb = Workbook()
            let ws = wb.addSheet("Executive Summary")
            var m = CoreDashboard.ExecutiveSummaryMetrics()
            m.fileVaultOffHardwareEncrypted = count
            CoreDashboard(config: ReportConfig(), dataDir: FileManager.default.temporaryDirectory,
                          workbook: wb).renderExecutiveSummaryRows(into: ws, metrics: m)
            XCTAssertFalse(labels(of: ws).contains("FileVault off, hardware-encrypted"),
                           "count \(String(describing: count))")
        }
    }
}
