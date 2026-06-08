import Foundation
import XCTest
@testable import JamfReports

// MARK: - SectionLimitsTests
//
// Verifies the Phase 6 `html.section_limits` config block:
//   - YAML round-trip
//   - Out-of-range clamping
//   - Renderer uses configurable cap vs hardcoded default
//   - insightsDrift multi-snapshot window

final class SectionLimitsTests: XCTestCase {

    // MARK: - Helpers

    private func makeReport(config: ReportConfig) -> HtmlReport {
        HtmlReport(config: config, dataDir: URL(fileURLWithPath: "/tmp/nonexistent"))
    }

    private func config(yaml: String) throws -> ReportConfig {
        try ConfigLoader.loadFromString(yaml)
    }

    // MARK: - YAML round-trip

    func testProtectAlertsCap50DecodesCorrectly() throws {
        let yaml = """
        html:
          section_limits:
            protect_alerts: 50
        """
        let c = try config(yaml: yaml)
        XCTAssertEqual(c.html?.sectionLimits?.protectAlerts, 50)
        XCTAssertEqual(c.html?.sectionLimits?.resolvedProtectAlerts, 50)
    }

    func testInsightsDriftSnapshotsCap4DecodesCorrectly() throws {
        let yaml = """
        html:
          section_limits:
            insights_drift_snapshots: 4
        """
        let c = try config(yaml: yaml)
        XCTAssertEqual(c.html?.sectionLimits?.insightsDriftSnapshots, 4)
        XCTAssertEqual(c.html?.sectionLimits?.resolvedInsightsDriftSnapshots, 4)
    }

    // MARK: - Defaults when block absent

    func testDefaultProtectAlertsIs25() throws {
        _ = try config(yaml: "columns:\n  computer_name: Name")
        let limits = HTMLSectionLimits()
        XCTAssertEqual(limits.resolvedProtectAlerts, 25)
    }

    func testDefaultInsightsDriftSnapshotsIs2() throws {
        let limits = HTMLSectionLimits()
        XCTAssertEqual(limits.resolvedInsightsDriftSnapshots, 2)
    }

    // MARK: - Clamping

    func testProtectAlertsOver200ClampsTo200() {
        var limits = HTMLSectionLimits()
        limits.protectAlerts = 500
        XCTAssertEqual(limits.resolvedProtectAlerts, 200)
    }

    func testProtectAlertsZeroClampsTo1() {
        var limits = HTMLSectionLimits()
        limits.protectAlerts = 0
        XCTAssertEqual(limits.resolvedProtectAlerts, 1)
    }

    func testProtectAlertsNegativeClampsTo1() {
        var limits = HTMLSectionLimits()
        limits.protectAlerts = -10
        XCTAssertEqual(limits.resolvedProtectAlerts, 1)
    }

    func testInsightsDriftSnapshotsOver12ClampsTo12() {
        var limits = HTMLSectionLimits()
        limits.insightsDriftSnapshots = 100
        XCTAssertEqual(limits.resolvedInsightsDriftSnapshots, 12)
    }

    func testInsightsDriftSnapshotsZeroClampsTo1() {
        var limits = HTMLSectionLimits()
        limits.insightsDriftSnapshots = 0
        XCTAssertEqual(limits.resolvedInsightsDriftSnapshots, 1)
    }

    // MARK: - Renderer: default cap is 25 (regression)

    func testProtectAlertsRendererDefaultCapIs25() throws {
        // Provide 30 alerts; with the default cap of 25, only 25 should be shown.
        let alerts: [[String: Any]] = (0 ..< 30).map { i in
            ["severity": "high", "device": "Mac-\(i)", "name": "Alert \(i)",
             "created": "2026-01-01"]
        }
        // Write to a temp directory so loadProtectJSON can find them.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SectionLimitsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let data = try JSONSerialization.data(withJSONObject: alerts)
        try data.write(to: tmp.appendingPathComponent("alerts_2026-01-01.json"))

        var cfg = ReportConfig().withDefaults()
        cfg.protect = ProtectConfig(enabled: true, profile: nil, dataDir: tmp.path)
        let html = makeReport(config: cfg).buildProtectAlerts(protectDataDir: tmp)

        // The title should show "showing 25 of 30".
        XCTAssertTrue(
            html.contains("showing 25 of 30"),
            "Default cap must limit protect alerts to 25; got: \(html)"
        )
    }

    // MARK: - insightsDrift: 4-snapshot window produces comparison columns

    func testInsightsDriftWith4SnapshotsProducesFourColumns() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SectionLimitsTests-Drift-\(UUID().uuidString)", isDirectory: true)
        let insightsDir = tmp.appendingPathComponent("insights", isDirectory: true)
        try FileManager.default.createDirectory(at: insightsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Write 4 snapshot files with distinct mtime spacing.
        for i in 0 ..< 4 {
            let snapshot: [String: Any] = ["total_alerts": i * 10]
            let data = try JSONSerialization.data(withJSONObject: snapshot)
            let url = insightsDir.appendingPathComponent("snap_\(i).json")
            try data.write(to: url)
            // Space mtime so chronological order is deterministic.
            let attrs = [FileAttributeKey.modificationDate:
                Date(timeIntervalSinceNow: TimeInterval(i - 4))]
            try FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
        }

        let yaml = """
        html:
          section_limits:
            insights_drift_snapshots: 4
        protect:
          enabled: true
          data_dir: "\(tmp.path)"
        """
        var cfg = try config(yaml: yaml)
        cfg = cfg.withDefaults()
        let html = makeReport(config: cfg).buildInsightsDrift(protectDataDir: tmp)

        // With 4 snapshots, headers should include "Current" and columns for older ones.
        XCTAssertTrue(html.contains("Current"), "Drift table must include 'Current' column")
        XCTAssertTrue(html.contains("Previous"), "Drift table must include 'Previous' column")
    }

    func testInsightsDriftFallsBackToTwoSnapshotsWhenFewerAvailable() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SectionLimitsTests-Drift2-\(UUID().uuidString)", isDirectory: true)
        let insightsDir = tmp.appendingPathComponent("insights", isDirectory: true)
        try FileManager.default.createDirectory(at: insightsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Write only 2 snapshots even though config requests 4.
        for i in 0 ..< 2 {
            let snapshot: [String: Any] = ["total_alerts": i * 5]
            let data = try JSONSerialization.data(withJSONObject: snapshot)
            let url = insightsDir.appendingPathComponent("snap_\(i).json")
            try data.write(to: url)
            let attrs = [FileAttributeKey.modificationDate:
                Date(timeIntervalSinceNow: TimeInterval(i - 2))]
            try FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
        }

        let yaml = """
        html:
          section_limits:
            insights_drift_snapshots: 4
        protect:
          enabled: true
          data_dir: "\(tmp.path)"
        """
        var cfg = try config(yaml: yaml)
        cfg = cfg.withDefaults()
        let html = makeReport(config: cfg).buildInsightsDrift(protectDataDir: tmp)

        // Should still produce a valid table (2 of 2 snapshots).
        XCTAssertTrue(html.contains("insights-drift"), "Section must render with fewer snapshots")
        XCTAssertTrue(html.contains("Current"), "Current column must appear")
        XCTAssertFalse(html.contains("2 ago"), "Should not reference snapshots beyond what's available")
    }
}
