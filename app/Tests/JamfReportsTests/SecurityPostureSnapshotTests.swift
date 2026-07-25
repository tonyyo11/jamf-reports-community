import Foundation
import XCTest
@testable import JamfReports

// MARK: - SecurityPostureSnapshotTests
//
// Validates `SecurityReportItem` JSON parsing directly — the decoder layer that
// feeds `CoreDashboard.writeSecurity()`. This is distinct from CoreDashboardSecurityTests,
// which validates the full sheet-write path. These tests assert field values and
// graceful fallback behaviour at the decode boundary.

final class SecurityPostureSnapshotTests: XCTestCase {

    // MARK: - Helpers

    private func fixtureURL(named name: String) -> URL {
        TestFixtures.dir("security_posture/\(name)")
    }

    private func decode(_ json: String) throws -> [SecurityReportItem] {
        let data = Data(json.utf8)
        return try JSONDecoder().decode([SecurityReportItem].self, from: data)
    }

    // MARK: - Happy path: canonical fixture

    func testCanonicalFixtureDecodesAllSections() throws {
        let url = fixtureURL(named: "canonical.json")
        let data = try Data(contentsOf: url)
        let items = try JSONDecoder().decode([SecurityReportItem].self, from: data)

        // 1 summary + 2 os_version + 1 device = 4 items
        XCTAssertEqual(items.count, 4)

        let summary = items.compactMap { if case .summary(let s) = $0 { return s } else { return nil } }.first
        XCTAssertNotNil(summary, "Expected one summary section")
        XCTAssertEqual(summary?.data.totalDevices, 150)
        XCTAssertEqual(summary?.data.fileVaultEncrypted, 142)
        XCTAssertEqual(summary?.data.gatekeeperEnabled, 150)
        XCTAssertEqual(summary?.data.sipEnabled, 149)
        XCTAssertEqual(summary?.data.firewallEnabled, 130)

        let osVersions = items.compactMap { if case .osVersion(let v) = $0 { return v } else { return nil } }
        XCTAssertEqual(osVersions.count, 2)
        XCTAssertEqual(osVersions[0].osVersion, "15.4.1")
        XCTAssertEqual(osVersions[0].count, 90)
        XCTAssertEqual(osVersions[1].osVersion, "14.7.5")

        let devices = items.compactMap { if case .device(let d) = $0 { return d } else { return nil } }
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].serial, "C02XY1234ABC")
    }

    // MARK: - Missing summary section: array without summary item decodes as unknown

    func testMissingSummarySectionDecodesWithoutCrash() throws {
        let json = """
        [
          {"section":"os_version","os_version":"15.4.1","count":10,"pct":"100%"},
          {"section":"device","name":"Mac-001","serial":"SN001"}
        ]
        """
        let items = try decode(json)

        XCTAssertEqual(items.count, 2)
        // No summary case — extracting summary returns nil, not a crash
        let summary = items.compactMap { if case .summary(let s) = $0 { return s } else { return nil } }.first
        XCTAssertNil(summary)

        // Other sections still decode normally
        let osVersions = items.compactMap { if case .osVersion(let v) = $0 { return v } else { return nil } }
        XCTAssertEqual(osVersions.count, 1)
    }

    // MARK: - Malformed JSON: non-array top level returns decode error

    func testMalformedJSONTopLevelObjectThrowsDecodeError() {
        let json = """
        {"section":"summary","data":{"total_devices":10}}
        """
        XCTAssertThrowsError(
            try decode(json),
            "Decoding a top-level object as [SecurityReportItem] must throw"
        )
    }

    // MARK: - Unknown section: decodes as .unknown, not crash

    func testUnknownSectionDecodesAsUnknownCase() throws {
        let json = """
        [
          {"section":"future_section","some_field":"value"},
          {"section":"summary","data":{"total_devices":5,"filevault_encrypted":5,
            "gatekeeper_enabled":5,"sip_enabled":5,"firewall_enabled":5}}
        ]
        """
        let items = try decode(json)

        XCTAssertEqual(items.count, 2)
        if case .unknown = items[0] {
            // Correct — unknown section round-trips to .unknown
        } else {
            XCTFail("Expected .unknown for unrecognised section, got \(items[0])")
        }
        if case .summary = items[1] {
            // Correct
        } else {
            XCTFail("Expected .summary for second item")
        }
    }

    // MARK: - Mixed legacy / current shapes: legacy fields are absent, optionals default nil

    func testSummaryWithMissingOptionalFieldsDefaultsToNil() throws {
        // A response that omits firewall_enabled — older jamf-cli or reduced permissions
        let json = """
        [
          {"section":"summary","data":{"total_devices":20,"filevault_encrypted":18,
            "gatekeeper_enabled":20,"sip_enabled":20}}
        ]
        """
        let items = try decode(json)
        let summary = items.compactMap { if case .summary(let s) = $0 { return s } else { return nil } }.first
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.data.totalDevices, 20)
        XCTAssertNil(summary?.data.firewallEnabled, "firewall_enabled should be nil when absent")
        XCTAssertNil(summary?.data.fileVaultEncryptedPct, "filevault_encrypted_pct absent means nil")
    }

    // MARK: - Empty array: decodes successfully to empty collection

    func testEmptyArrayDecodesWithoutCrash() throws {
        let items = try decode("[]")
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - OS version pct field preserved verbatim

    func testOSVersionPctPreservedVerbatim() throws {
        let json = """
        [{"section":"os_version","os_version":"15.4.1","count":75,"pct":"75%"}]
        """
        let items = try decode(json)
        let ver = items.compactMap { if case .osVersion(let v) = $0 { return v } else { return nil } }.first
        XCTAssertEqual(ver?.pct, "75%")
    }
}
