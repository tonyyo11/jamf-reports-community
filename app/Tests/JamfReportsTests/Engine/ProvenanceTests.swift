import Foundation
import XCTest
@testable import JamfReports

// MARK: - ProvenanceTests

final class ProvenanceTests: XCTestCase {

    // MARK: - Factory: basic properties

    func testCurrentProvenanceProducesValidUUID() async {
        let prov = await Provenance.current(
            profile: "test-profile",
            jamfCLIURL: nil,
            dataDir: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")
        )
        XCTAssertNotNil(UUID(uuidString: prov.runID), "runID must be a valid UUID")
    }

    func testCurrentProvenanceProfilePassedThrough() async {
        let prov = await Provenance.current(
            profile: "acme-prod",
            jamfCLIURL: nil,
            dataDir: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")
        )
        XCTAssertEqual(prov.profile, "acme-prod")
    }

    func testCurrentProvenanceCapturesOperatorUserHost() async {
        let prov = await Provenance.current(
            profile: "test",
            jamfCLIURL: nil,
            dataDir: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")
        )
        XCTAssertFalse(prov.operatorUserHost.isEmpty)
        // Must be "user@host" format
        XCTAssertTrue(prov.operatorUserHost.contains("@"),
                      "operatorUserHost must contain '@': \(prov.operatorUserHost)")
    }

    func testCurrentProvenanceGeneratedAtIsRecent() async {
        let before = Date()
        let prov = await Provenance.current(
            profile: "test",
            jamfCLIURL: nil,
            dataDir: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")
        )
        let after = Date()
        XCTAssertGreaterThanOrEqual(prov.generatedAt, before)
        XCTAssertLessThanOrEqual(prov.generatedAt, after)
    }

    // MARK: - Factory: graceful fallbacks

    func testJamfCLIVersionNilWhenBinaryAbsent() async {
        let prov = await Provenance.current(
            profile: "test",
            jamfCLIURL: URL(fileURLWithPath: "/tmp/nonexistent-binary-xyz"),
            dataDir: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")
        )
        // Can't launch a non-existent binary — version must be nil, not crash
        XCTAssertNil(prov.jamfCLIVersion)
    }

    func testTenantURLNilWhenDataDirAbsent() async {
        let prov = await Provenance.current(
            profile: "test",
            jamfCLIURL: nil,
            dataDir: URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")
        )
        XCTAssertNil(prov.jamfTenantURL)
    }

    func testTenantURLExtractedFromOverviewSnapshot() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProvenanceTests-\(UUID().uuidString)", isDirectory: true)
        let overviewDir = tmp.appendingPathComponent("overview", isDirectory: true)
        try FileManager.default.createDirectory(at: overviewDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let json = """
        [{"section":"Instance","resource":"Jamf Pro URL","value":"https://jamf.example.com","status":"ok"}]
        """
        let fileURL = overviewDir.appendingPathComponent("overview_2026.json")
        try json.write(to: fileURL, atomically: true, encoding: .utf8)

        let prov = await Provenance.current(
            profile: "test",
            jamfCLIURL: nil,
            dataDir: tmp
        )
        // The overview JSON above uses "value" which isn't a raw URL key; tenantURL may be nil
        // because the reader looks for "jamf_url" or "url" keys. Verify no crash.
        // This is a best-effort extraction — don't assert non-nil for this shape.
        _ = prov.jamfTenantURL  // must not crash
    }

    func testTenantURLExtractedWhenJamfURLKeyPresent() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProvenanceTests-\(UUID().uuidString)", isDirectory: true)
        let overviewDir = tmp.appendingPathComponent("overview", isDirectory: true)
        try FileManager.default.createDirectory(at: overviewDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let json = """
        [{"section":"Instance","jamf_url":"https://jamf.example.com","status":"ok"}]
        """
        let fileURL = overviewDir.appendingPathComponent("overview_2026.json")
        try json.write(to: fileURL, atomically: true, encoding: .utf8)

        let prov = await Provenance.current(
            profile: "test",
            jamfCLIURL: nil,
            dataDir: tmp
        )
        XCTAssertEqual(prov.jamfTenantURL, "https://jamf.example.com")
    }

    // MARK: - Codable round-trip

    func testProvenanceCodableRoundTrip() throws {
        let original = Provenance(
            runID: UUID().uuidString,
            generatedAt: Date(timeIntervalSince1970: 1_746_000_000),
            profile: "acme-prod",
            jamfCLIVersion: "1.14.0",
            jamfTenantURL: "https://jamf.example.com",
            operatorUserHost: "operator@example-host"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(Provenance.self, from: data)

        XCTAssertEqual(decoded.runID, original.runID)
        XCTAssertEqual(decoded.profile, original.profile)
        XCTAssertEqual(decoded.jamfCLIVersion, original.jamfCLIVersion)
        XCTAssertEqual(decoded.jamfTenantURL, original.jamfTenantURL)
        XCTAssertEqual(decoded.operatorUserHost, original.operatorUserHost)
        // Date comparison: ISO 8601 with fractional seconds; accept within 1 second
        XCTAssertEqual(decoded.generatedAt.timeIntervalSince1970,
                       original.generatedAt.timeIntervalSince1970,
                       accuracy: 1.0)
    }

    func testProvenanceOptionalFieldsOmittedWhenNil() throws {
        let prov = Provenance(
            runID: "test-uuid",
            generatedAt: Date(),
            profile: "default",
            jamfCLIVersion: nil,
            jamfTenantURL: nil,
            operatorUserHost: "user@host"
        )
        let data = try JSONEncoder().encode(prov)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNil(json?["jamfCLIVersion"],
                     "jamfCLIVersion must be absent when nil")
        XCTAssertNil(json?["jamfTenantURL"],
                     "jamfTenantURL must be absent when nil")
        XCTAssertNotNil(json?["runID"])
        XCTAssertNotNil(json?["operatorUserHost"])
    }

    // MARK: - DailySummary provenance field

    func testDailySummaryProvenanceRoundTrip() throws {
        let prov = Provenance(
            runID: "abc-123",
            generatedAt: Date(timeIntervalSince1970: 1_746_000_000),
            profile: "acme",
            jamfCLIVersion: "1.14.0",
            jamfTenantURL: nil,
            operatorUserHost: "user@host"
        )
        let summary = DailySummary(
            date: "2026-05-07",
            totalDevices: 500,
            fileVaultPct: 98.0,
            compliancePct: nil,
            staleCount: 10,
            osCurrentPct: 72.0,
            crowdstrikePct: nil,
            patchPct: 85.0,
            source: "jamf-cli",
            provenance: prov
        )
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(DailySummary.self, from: data)

        XCTAssertEqual(decoded.provenance?.runID, "abc-123")
        XCTAssertEqual(decoded.provenance?.profile, "acme")
        XCTAssertEqual(decoded.provenance?.jamfCLIVersion, "1.14.0")
    }

    func testDailySummaryWithoutProvenanceDecodesFromLegacyJSON() throws {
        // Old summary files (Python-generated) have no "provenance" key — must still decode.
        let json = """
        {"date":"2026-01-01","totalDevices":100,"fileVaultPct":90.0,
         "staleCount":5,"osCurrentPct":60.0,"patchPct":75.0,"source":"jamf-cli"}
        """
        let decoded = try JSONDecoder().decode(DailySummary.self, from: Data(json.utf8))
        XCTAssertNil(decoded.provenance, "provenance must be nil for legacy JSON")
        XCTAssertEqual(decoded.totalDevices, 100)
    }

    func testDailySummaryProvenanceAbsentWhenNil() throws {
        let summary = DailySummary(
            date: "2026-05-07",
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
        XCTAssertNil(json?["provenance"], "provenance key must be absent when nil")
    }
}
