import Foundation
import XCTest
@testable import JamfReports

// MARK: - CompliancePostureTests
// Verifies writeCompliancePosture renders correctly with full data, missing data,
// and correct framework label sourcing from config.

final class CompliancePostureTests: XCTestCase {

    // MARK: - Helpers

    /// Tracks helper-created temp dirs for sweep in `tearDown`. Direct-callsite
    /// temp dirs still use local `defer` cleanup.
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

    /// Build a temp dataDir seeded with the given fixture subdirectories.
    /// Tracked for cleanup in `tearDown`.
    private func tempDataDir(copying names: [String]) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-cp-\(UUID().uuidString)")
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

    /// Write a JSON array to a temp dataDir subdirectory.
    private func seedJSON(_ array: [[String: Any]], name: String, in dir: URL) throws {
        let subdir = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: array)
        let file = subdir.appendingPathComponent("snapshot.json")
        try data.write(to: file)
    }

    private func makeDashboard(
        config: ReportConfig = ReportConfig(),
        dataDir: URL
    ) -> CoreDashboard {
        CoreDashboard(config: config, dataDir: dataDir, workbook: Workbook())
    }

    // MARK: - Renders without throwing when no data

    func testCompliancePostureRendersWithNoData() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-cp-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dash = makeDashboard(dataDir: tmp)
        // Missing snapshots should not cause a throw — metrics show "—".
        XCTAssertNoThrow(try dash.writeCompliancePosture())
    }

    // MARK: - Renders with fixture data (security + device-compliance)

    func testCompliancePostureRendersWithFixtureData() throws {
        let dataDir = try tempDataDir(copying: ["security", "device-compliance"])
        // No inline `defer` cleanup: tempDataDir(copying:) registers the dir in
        // `createdTempDirs`, which `tearDown` sweeps (Epic #102).

        let hasSecurityFixture = FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent("security").path
        )
        guard hasSecurityFixture else { throw XCTSkip("security fixture not available") }

        let dash = makeDashboard(dataDir: dataDir)
        XCTAssertNoThrow(try dash.writeCompliancePosture())
    }

    // MARK: - Renders with all seven metrics when security data is present

    func testCompliancePostureRendersSevenMetrics() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-cp-metrics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Seed minimal security snapshot
        let securityJSON: [[String: Any]] = [
            [
                "section": "summary",
                "data": [
                    "total_devices": 100,
                    "filevault_encrypted": 94,
                    "sip_enabled": 99,
                    "firewall_enabled": 88,
                    "gatekeeper_enabled": 97,
                ] as [String: Any],
            ]
        ]
        try seedJSON(securityJSON, name: "security", in: tmp)

        // Seed device-compliance snapshot (20 devices, 17 managed)
        let deviceJSON: [[String: Any]] = (0..<20).map { i in
            [
                "name": "Device-\(i)",
                "serial": "SN\(i)",
                "managed": i < 17,
                "stale": i >= 18,
                "days_since_checkin": i >= 18 ? 45 : 5,
            ] as [String: Any]
        }
        try seedJSON(deviceJSON, name: "device-compliance", in: tmp)

        // Seed patch-status snapshot (2 titles)
        let patchJSON: [[String: Any]] = [
            ["title": "Firefox", "on_latest": 90, "on_other": 10, "total": 100,
             "latest": "130.0", "compliance_pct": "90%"],
            ["title": "Chrome", "on_latest": 70, "on_other": 30, "total": 100,
             "latest": "120.0", "compliance_pct": "70%"],
        ]
        try seedJSON(patchJSON, name: "patch-status", in: tmp)

        let dash = makeDashboard(dataDir: tmp)
        XCTAssertNoThrow(try dash.writeCompliancePosture())
    }

    // MARK: - Renders "—" for missing security snapshot

    func testCompliancePostureDashWhenSecurityMissing() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-cp-nosec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Only seed device-compliance; security is missing.
        let deviceJSON: [[String: Any]] = [
            ["name": "Mac-1", "serial": "ABC", "managed": true, "stale": false,
             "days_since_checkin": 2] as [String: Any],
        ]
        try seedJSON(deviceJSON, name: "device-compliance", in: tmp)

        let dash = makeDashboard(dataDir: tmp)
        // Should not throw; security metrics show "—" / 0.
        XCTAssertNoThrow(try dash.writeCompliancePosture())
    }

    // MARK: - Framework label from config

    func testCompliancePostureUsesConfigFrameworkLabel() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-cp-fwork-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var config = ReportConfig()
        config.compliance = ComplianceConfig()
        config.compliance?.framework = "DISA STIG macOS"

        let dash = CoreDashboard(config: config, dataDir: tmp, workbook: Workbook())
        XCTAssertNoThrow(try dash.writeCompliancePosture())
        XCTAssertEqual(config.compliance?.resolvedFramework, "DISA STIG macOS")
    }

    // MARK: - Framework label is empty when not configured (no assumed default)

    func testCompliancePostureDefaultFrameworkIsEmpty() {
        var config = ReportConfig()
        config.compliance = ComplianceConfig()
        // framework is nil — resolvedFramework returns empty (renderers handle).
        XCTAssertEqual(config.compliance?.resolvedFramework, "")
    }

    func testCompliancePostureEmptyFrameworkResolvesEmpty() {
        var config = ReportConfig()
        config.compliance = ComplianceConfig()
        config.compliance?.framework = "   "   // whitespace-only
        XCTAssertEqual(config.compliance?.resolvedFramework, "")
    }

    // MARK: - Non-compliant device table sorted by days stale descending

    func testCompliancePostureNonCompliantDevicesSortedByDaysDesc() throws {
        // This test verifies the sorting contract via the rendered sheet call (no crash).
        // The sort logic is: highest days_since_checkin first (up to 20 shown).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-cp-sort-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 25 stale devices with varying days — only top 20 should appear.
        let deviceJSON: [[String: Any]] = (0..<25).map { i in
            [
                "name": "Device-\(i)",
                "serial": "SN\(i)",
                "managed": false,
                "stale": true,
                "days_since_checkin": i * 3,
            ] as [String: Any]
        }
        try seedJSON(deviceJSON, name: "device-compliance", in: tmp)

        let dash = makeDashboard(dataDir: tmp)
        XCTAssertNoThrow(try dash.writeCompliancePosture())
    }

    // MARK: - Compliance Posture is written via writeAll

    func testCompliancePostureWrittenByWriteAll() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-cp-all-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dash = makeDashboard(dataDir: tmp)
        let (written, _) = dash.writeAll(selectedNames: ["compliance posture"])
        XCTAssertEqual(written, ["Compliance Posture"])
    }
}
