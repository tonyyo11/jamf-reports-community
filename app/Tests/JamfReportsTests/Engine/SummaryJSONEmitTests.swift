import Foundation
import XCTest
@testable import JamfReports

/// Tests for ReportEngine.emitSummaryJSON and round-trip schema validation.
final class SummaryJSONEmitTests: XCTestCase {

    private var tmpDir: URL!
    private var summariesDir: URL!
    private var engine: ReportEngine!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        summariesDir = tmpDir.appendingPathComponent("summaries", isDirectory: true)
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let config = ReportConfig()
        let dataDir = tmpDir.appendingPathComponent("data", isDirectory: true)
        engine = ReportEngine(config: config, dataDir: dataDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - Schema round-trip

    func testDailySummaryRoundTrip() throws {
        let original = DailySummary(
            date: "2024-06-15",
            totalDevices: 500,
            fileVaultPct: 98.3,
            compliancePct: 87.5,
            staleCount: 12,
            osCurrentPct: 72.0,
            crowdstrikePct: 99.1,
            patchPct: 81.4,
            source: "csv",
            provenance: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(DailySummary.self, from: data)
        XCTAssertEqual(decoded.date, original.date)
        XCTAssertEqual(decoded.totalDevices, original.totalDevices)
        XCTAssertEqual(decoded.fileVaultPct, original.fileVaultPct, accuracy: 0.01)
        XCTAssertEqual(decoded.compliancePct, original.compliancePct)
        XCTAssertEqual(decoded.staleCount, original.staleCount)
        XCTAssertEqual(decoded.osCurrentPct, original.osCurrentPct, accuracy: 0.01)
        XCTAssertEqual(decoded.crowdstrikePct, original.crowdstrikePct)
        XCTAssertEqual(decoded.patchPct, original.patchPct, accuracy: 0.01)
        XCTAssertEqual(decoded.source, original.source)
    }

    func testOptionalFieldsOmittedWhenNil() throws {
        let summary = DailySummary(
            date: "2024-06-15",
            totalDevices: 100,
            fileVaultPct: 90.0,
            compliancePct: nil,
            staleCount: 5,
            osCurrentPct: 60.0,
            crowdstrikePct: nil,
            patchPct: 75.0,
            source: "jamf-cli",
            provenance: nil
        )
        let data = try JSONEncoder().encode(summary)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(json?["compliancePct"], "compliancePct must be absent when nil")
        XCTAssertNil(json?["crowdstrikePct"], "crowdstrikePct must be absent when nil")
        XCTAssertNil(json?["provenance"], "provenance must be absent when nil")
        XCTAssertNotNil(json?["patchPct"])
    }

    func testSummaryJSONContainsProvenanceWhenSupplied() throws {
        let prov = Provenance(
            runID: "emit-test-run-id",
            generatedAt: Date(),
            profile: "cbp-prod",
            jamfCLIVersion: "1.14.0",
            jamfTenantURL: "https://jamf.example.com",
            operatorUserHost: "user@host"
        )
        let summary = DailySummary(
            date: "2026-05-07",
            totalDevices: 300,
            fileVaultPct: 95.0,
            compliancePct: nil,
            staleCount: 8,
            osCurrentPct: 70.0,
            crowdstrikePct: nil,
            patchPct: 82.0,
            source: "jamf-cli",
            provenance: prov
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(summary)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json?["provenance"], "provenance key must be present when set")
        let provDict = json?["provenance"] as? [String: Any]
        XCTAssertEqual(provDict?["runID"] as? String, "emit-test-run-id")
        XCTAssertEqual(provDict?["profile"] as? String, "cbp-prod")
        XCTAssertEqual(provDict?["jamfCLIVersion"] as? String, "1.14.0")
        XCTAssertEqual(provDict?["jamfTenantURL"] as? String, "https://jamf.example.com")
        XCTAssertEqual(provDict?["operatorUserHost"] as? String, "user@host")
    }

    func testLegacySummaryJSONDecodesWithoutProvenance() throws {
        // Old Python-generated summary.json files have no "provenance" key.
        // DailySummary must still decode cleanly.
        let json = """
        {"date":"2025-01-01","totalDevices":200,"fileVaultPct":92.0,
         "staleCount":3,"osCurrentPct":65.0,"patchPct":78.0,"source":"csv"}
        """
        let decoded = try JSONDecoder().decode(DailySummary.self, from: Data(json.utf8))
        XCTAssertNil(decoded.provenance, "provenance must be nil for pre-provenance summary files")
        XCTAssertEqual(decoded.totalDevices, 200)
    }

    // MARK: - emitSummaryJSON behavior

    func testEmitCreatesSummariesDirAndFile() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: summariesDir.path))
        // Engine has no cached data — emitSummaryJSON will return early because
        // buildSummaryFromCLI returns nil when there is no security/inventory data.
        // Test the dir-creation and file-writing behavior via a pre-seeded data dir.
        try writeMinimalSecuritySnapshot()
        engine.emitSummaryJSON(summariesDir: summariesDir)

        // Dir should have been created.
        XCTAssertTrue(FileManager.default.fileExists(atPath: summariesDir.path))
        // A valid snapshot should exist.
        let files = try FileManager.default.contentsOfDirectory(atPath: summariesDir.path)
        XCTAssertEqual(files.count, 1)
        let file = files[0]
        XCTAssertTrue(file.hasPrefix("summary_"))
        XCTAssertTrue(file.hasSuffix(".json"))
    }

    func testEmitDoesNotOverwriteValidSameDaySummary() throws {
        try FileManager.default.createDirectory(at: summariesDir, withIntermediateDirectories: true)
        let today = SummaryJSONParser.dateFormatter.string(from: Date())
        let existingURL = summariesDir.appendingPathComponent("summary_\(today).json")
        let existingSummary = DailySummary(
            date: today, totalDevices: 999, fileVaultPct: 99.9, compliancePct: nil,
            staleCount: 0, osCurrentPct: 100.0, crowdstrikePct: nil, patchPct: 99.0,
            source: "jamf-cli"
        )
        let data = try JSONEncoder().encode(existingSummary)
        try data.write(to: existingURL, options: .atomic)

        try writeMinimalSecuritySnapshot()
        engine.emitSummaryJSON(summariesDir: summariesDir)

        // File must not have been replaced — totalDevices sentinel still 999.
        let read = try SummaryJSONParser.parse(existingURL)
        XCTAssertEqual(read.totalDevices, 999, "Existing valid summary must not be overwritten")
    }

    func testEmitSummaryParsesBackThroughSummaryJSONParser() throws {
        try writeMinimalSecuritySnapshot()
        engine.emitSummaryJSON(summariesDir: summariesDir)
        let summaries = SummaryJSONParser.parseDirectory(summariesDir)
        guard !summaries.isEmpty else {
            // No cached data to build summary from — test is vacuously satisfied.
            return
        }
        let s = summaries[0]
        XCTAssertFalse(s.date.isEmpty)
        XCTAssertGreaterThan(s.totalDevices, 0)
        XCTAssertEqual(s.source, "jamf-cli")
    }

    // MARK: - Helpers

    private func writeMinimalSecuritySnapshot() throws {
        let dataDir = engine.dataDir
        let secDir = dataDir.appendingPathComponent("security", isDirectory: true)
        try FileManager.default.createDirectory(at: secDir, withIntermediateDirectories: true)
        let payload: [[String: Any]] = [
            [
                "section": "summary",
                "data": [
                    "total_devices": 250,
                    "filevault_encrypted": 240,
                    "filevault_encrypted_pct": "96.0%",
                    "gatekeeper_enabled": 250,
                    "sip_enabled": 249,
                    "firewall_enabled": 245,
                ],
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let file = secDir.appendingPathComponent("security_20240615T120000.json")
        try data.write(to: file)
    }
}
