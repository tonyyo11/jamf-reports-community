import Foundation
import XCTest
@testable import JamfReports

final class LegacyHistoryImporterTests: XCTestCase {

    private var tempRoot: URL!
    private var sourceFile: URL!
    private var destDir: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        sourceFile = tempRoot.appendingPathComponent("history.json")
        destDir = tempRoot.appendingPathComponent("summaries")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func writeSource(_ entries: [[String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: entries, options: [])
        try data.write(to: sourceFile)
    }

    func testImportsLegacyEntryAndConvertsDateFormat() throws {
        try writeSource([[
            "total_devices": 655,
            "filevault_compliant": 647,
            "sip_compliant": 655,
            "firewall_compliant": 655,
            "crowdstrike_connected": 635,
            "xprotect_current": 566,
            "cve_clean": 636,
            "secure_boot_full": 608,
            "bootstrap_escrowed": 647,
            "no_baseline_active": 17,
            "mscp_score_pct": 95.4,
            "security_score": 97.2,
            "action_items_p0": 8,
            "action_items_p1": 109,
            "action_items_p2": 0,
            "date": "20260511",
        ]])

        let outcome = try LegacyHistoryImporter.importHistory(from: sourceFile, to: destDir)

        XCTAssertEqual(outcome.imported, ["2026-05-11"])
        XCTAssertTrue(outcome.skipped.isEmpty)
        XCTAssertTrue(outcome.invalid.isEmpty)

        let written = destDir.appendingPathComponent("summary_2026-05-11.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))

        // Round-trip through SummaryJSONParser to confirm the file is the
        // canonical shape TrendStore expects.
        let summary = try SummaryJSONParser.parse(written)
        XCTAssertEqual(summary.date, "2026-05-11")
        XCTAssertEqual(summary.totalDevices, 655)
        XCTAssertEqual(summary.fileVaultPct ?? -1, 98.78, accuracy: 0.05,
                       "filevault_compliant/total_devices ≈ 98.78%")
        XCTAssertEqual(summary.sipPct ?? -1, 100.0, accuracy: 0.05)
        XCTAssertEqual(summary.firewallPct ?? -1, 100.0, accuracy: 0.05)
        XCTAssertEqual(summary.mscpScorePct, 95.4)
        XCTAssertEqual(summary.compliancePct, 95.4,
                       "mscp_score_pct should populate the existing compliance trend slot")
        XCTAssertEqual(summary.securityScore, 97.2)
        XCTAssertEqual(summary.actionItemsP0, 8)
        XCTAssertEqual(summary.actionItemsP1, 109)
        XCTAssertEqual(summary.noBaselineActive, 17)
        XCTAssertEqual(summary.source, "legacy-import")
    }

    func testIdempotentByDefault() throws {
        try writeSource([[
            "total_devices": 100,
            "filevault_compliant": 100,
            "date": "20260501",
        ]])

        let first = try LegacyHistoryImporter.importHistory(from: sourceFile, to: destDir)
        XCTAssertEqual(first.imported, ["2026-05-01"])

        let second = try LegacyHistoryImporter.importHistory(from: sourceFile, to: destDir)
        XCTAssertTrue(second.imported.isEmpty,
                      "Second run should not re-write existing summary files")
        XCTAssertEqual(second.skipped, ["2026-05-01"])
    }

    func testOverwriteFlagReplacesExistingFile() throws {
        try writeSource([[
            "total_devices": 100,
            "filevault_compliant": 50,
            "date": "20260501",
        ]])
        _ = try LegacyHistoryImporter.importHistory(from: sourceFile, to: destDir)

        // Mutate source and re-import with overwrite=true.
        try writeSource([[
            "total_devices": 100,
            "filevault_compliant": 95,
            "date": "20260501",
        ]])
        let outcome = try LegacyHistoryImporter.importHistory(
            from: sourceFile, to: destDir, overwriteExisting: true
        )

        XCTAssertEqual(outcome.imported, ["2026-05-01"])
        let summary = try SummaryJSONParser.parse(
            destDir.appendingPathComponent("summary_2026-05-01.json")
        )
        XCTAssertEqual(summary.fileVaultPct ?? -1, 95.0, accuracy: 0.01)
    }

    func testInvalidDateIsCountedNotThrown() throws {
        try writeSource([
            ["total_devices": 100, "filevault_compliant": 100, "date": "20260501"],
            ["total_devices": 100, "filevault_compliant": 100, "date": "not-a-date"],
            ["total_devices": 100, "filevault_compliant": 100, "date": "2026-05-02"],
        ])

        let outcome = try LegacyHistoryImporter.importHistory(from: sourceFile, to: destDir)

        XCTAssertEqual(Set(outcome.imported), Set(["2026-05-01", "2026-05-02"]),
                       "Valid entries should still be imported")
        XCTAssertEqual(outcome.invalid, ["not-a-date"])
        XCTAssertEqual(outcome.totalParsed, 3)
    }

    func testMissingFileThrowsFileNotFound() {
        let missing = tempRoot.appendingPathComponent("does-not-exist.json")
        XCTAssertThrowsError(
            try LegacyHistoryImporter.importHistory(from: missing, to: destDir)
        ) { error in
            guard case LegacyHistoryImporter.Failure.fileNotFound = error else {
                return XCTFail("Expected .fileNotFound, got \(error)")
            }
        }
    }

    func testEmptyHistoryArrayThrowsNoEntries() throws {
        try writeSource([])
        XCTAssertThrowsError(
            try LegacyHistoryImporter.importHistory(from: sourceFile, to: destDir)
        ) { error in
            guard case LegacyHistoryImporter.Failure.noEntries = error else {
                return XCTFail("Expected .noEntries, got \(error)")
            }
        }
    }
}
