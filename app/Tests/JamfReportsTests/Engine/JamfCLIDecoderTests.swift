import Foundation
import XCTest
@testable import JamfReports

final class JamfCLIDecoderTests: XCTestCase {

    // MARK: - SecurityReportItem

    func testSecuritySummaryDecoding() throws {
        let json = """
        [{"section":"summary","data":{"total_devices":101,"filevault_encrypted":100,
        "gatekeeper_enabled":98,"sip_enabled":95,"firewall_enabled":10}}]
        """
        let items = try JSONDecoder().decode([SecurityReportItem].self, from: Data(json.utf8))
        guard case .summary(let s) = items[0] else {
            XCTFail("Expected .summary"); return
        }
        XCTAssertEqual(s.data.totalDevices, 101)
        XCTAssertEqual(s.data.fileVaultEncrypted, 100)
        XCTAssertEqual(s.data.firewallEnabled, 10)
    }

    func testSecurityOSVersionDecoding() throws {
        let json = """
        [{"section":"os_version","os_version":"15.4.1","count":42,"pct":"41%"}]
        """
        let items = try JSONDecoder().decode([SecurityReportItem].self, from: Data(json.utf8))
        guard case .osVersion(let v) = items[0] else {
            XCTFail("Expected .osVersion"); return
        }
        XCTAssertEqual(v.osVersion, "15.4.1")
        XCTAssertEqual(v.count, 42)
    }

    func testSecurityFixtureDecodesWithoutError() throws {
        let fixtureURL = fixturesDir
            .appendingPathComponent("jamf-cli-data/security/security.json")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("Fixture not available")
        }

        let data = try Data(contentsOf: fixtureURL)
        let items = try JSONDecoder().decode([SecurityReportItem].self, from: data)

        // Must have at least a summary section.
        let hasSummary = items.contains { if case .summary = $0 { return true }; return false }
        XCTAssertTrue(hasSummary, "Security fixture should contain a summary section")
    }

    // MARK: - PatchStatusRow

    func testPatchStatusV114ShapeDecoding() throws {
        // v1.14 uses on_latest / on_other — NOT installed / total.
        let json = """
        [{"title":"Firefox","id":"42","on_latest":80,"on_other":20,
          "total":100,"latest":"130.0","compliance_pct":"80%"}]
        """
        let rows = try JSONDecoder().decode([PatchStatusRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows[0].title, "Firefox")
        XCTAssertEqual(rows[0].onLatest, 80)
        XCTAssertEqual(rows[0].onOther, 20)
        XCTAssertEqual(rows[0].latest, "130.0")
    }

    func testPatchStatusFixtureDecodesWithoutError() throws {
        let fixtureURL = fixturesDir
            .appendingPathComponent("jamf-cli-data/patch-status/patch-status.json")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("Fixture not available")
        }

        let data = try Data(contentsOf: fixtureURL)
        XCTAssertNoThrow(
            try JSONDecoder().decode([PatchStatusRow].self, from: data)
        )
    }

    // MARK: - OverviewRow

    func testOverviewRowDecoding() throws {
        let json = """
        [{"section":"Health & Alerts","resource":"Health Status","value":"ok"}]
        """
        let decoder = JSONDecoder()
        let rows = try decoder.decode([OverviewRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows[0].resource, "Health Status")
        XCTAssertEqual(rows[0].section, "Health & Alerts")
    }

    func testOverviewFixtureDecodesWithoutError() throws {
        let fixtureURL = fixturesDir
            .appendingPathComponent("jamf-cli-data/overview/overview.json")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("Fixture not available")
        }

        let data = try Data(contentsOf: fixtureURL)
        XCTAssertNoThrow(
            try JSONDecoder().decode([OverviewRow].self, from: data)
        )
    }

    // MARK: - AnyCodable

    func testAnyCodableRoundtripsString() throws {
        let original = AnyCodable("hello")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.description, "hello")
    }

    func testAnyCodableRoundtripsInt() throws {
        let original = AnyCodable(42)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.description, "42")
    }

    func testAnyCodableNilHandled() {
        let v = AnyCodable(nil)
        // nil value produces an empty string via stringValue's default branch.
        XCTAssertEqual(v.description, "")
    }

    // MARK: - ExtensionAttribute

    func testExtensionAttributeDecodesBooleanDataType() throws {
        let json = """
        [{"id":"1","name":"FileVault Status","description":"FV2 state",
          "dataType":"BOOLEAN","inputType":"SCRIPT","enabled":true}]
        """
        let eas = try JSONDecoder().decode([ExtensionAttribute].self, from: Data(json.utf8))
        XCTAssertEqual(eas.count, 1)
        XCTAssertEqual(eas[0].id, "1")
        XCTAssertEqual(eas[0].name, "FileVault Status")
        XCTAssertEqual(eas[0].dataType, "BOOLEAN")
        XCTAssertEqual(eas[0].inputType, "SCRIPT")
        XCTAssertEqual(eas[0].enabled, true)
        XCTAssertEqual(eas[0].inferredEAType, "boolean")
    }

    func testExtensionAttributeDecodesDateDataType() throws {
        let json = """
        [{"id":"2","name":"Cert Expiry","dataType":"DATE","inputType":"SCRIPT","enabled":true}]
        """
        let eas = try JSONDecoder().decode([ExtensionAttribute].self, from: Data(json.utf8))
        XCTAssertEqual(eas[0].inferredEAType, "date")
    }

    func testExtensionAttributeDecodesIntegerAsPercentage() throws {
        let json = """
        [{"id":"3","name":"Disk Usage","dataType":"INTEGER","inputType":"SCRIPT","enabled":true}]
        """
        let eas = try JSONDecoder().decode([ExtensionAttribute].self, from: Data(json.utf8))
        XCTAssertEqual(eas[0].inferredEAType, "percentage")
    }

    func testExtensionAttributeDecodesStringAsText() throws {
        let json = """
        [{"id":"4","name":"OS Version EA","dataType":"STRING","inputType":"TEXT","enabled":false}]
        """
        let eas = try JSONDecoder().decode([ExtensionAttribute].self, from: Data(json.utf8))
        XCTAssertEqual(eas[0].inferredEAType, "text")
        XCTAssertEqual(eas[0].enabled, false)
    }

    func testExtensionAttributeFixtureDecodesWithoutError() throws {
        let fixtureURL = fixturesDir
            .appendingPathComponent("jamf-cli-data/computer-extension-attributes")
            .appendingPathComponent("computer-extension-attributes.json")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("EA fixture not available")
        }
        let data = try Data(contentsOf: fixtureURL)
        let eas = try JSONDecoder().decode([ExtensionAttribute].self, from: data)
        XCTAssertFalse(eas.isEmpty, "EA fixture must decode at least one record")
        // Every record should have a name.
        XCTAssertTrue(eas.allSatisfy { $0.name != nil })
        // inferredEAType should never be empty.
        XCTAssertTrue(eas.allSatisfy { !$0.inferredEAType.isEmpty })
    }

    // MARK: - UpdateStatusReport

    func testUpdateStatusReportDecoding() throws {
        let json = """
        [{"total":120,"status_summary":[{"status":"PENDING","count":10},{"status":"UP_TO_DATE","count":110}],
          "plan_total":5,"plan_state_summary":[{"state":"Activated","count":3}]}]
        """
        let reports = try JSONDecoder().decode([UpdateStatusReport].self, from: Data(json.utf8))
        XCTAssertEqual(reports.count, 1)
        let r = reports[0]
        XCTAssertEqual(r.total, 120)
        XCTAssertEqual(r.statusSummary.count, 2)
        XCTAssertEqual(r.statusSummary[0].status, "PENDING")
        XCTAssertEqual(r.statusSummary[0].count, 10)
        XCTAssertEqual(r.planTotal, 5)
        XCTAssertEqual(r.planStateSummary?.first?.state, "Activated")
    }

    func testUpdateStatusReportOptionalPlanFields() throws {
        // plan_total and plan_state_summary are optional — must decode without them.
        let json = """
        [{"total":50,"status_summary":[{"status":"UP_TO_DATE","count":50}]}]
        """
        let reports = try JSONDecoder().decode([UpdateStatusReport].self, from: Data(json.utf8))
        XCTAssertEqual(reports[0].total, 50)
        XCTAssertNil(reports[0].planTotal)
        XCTAssertNil(reports[0].planStateSummary)
    }

    func testPatchStatusRowDecodesTwice() throws {
        // PatchStatusRow is Decodable-only. Verify field names decode correctly
        // from two different JSON representations (object and array).
        let json = """
        {"title":"Chrome","id":"1","on_latest":90,"on_other":10,
         "total":100,"latest":"123.0","compliance_pct":"90%"}
        """
        let row = try JSONDecoder().decode(PatchStatusRow.self, from: Data(json.utf8))
        XCTAssertEqual(row.title, "Chrome")
        XCTAssertEqual(row.onLatest, 90)
        XCTAssertEqual(row.onOther, 10)
        XCTAssertEqual(row.compliancePct, "90%")
        // Decode from array — verifies the snake_case key mapping
        let arrayJSON = "[\(json)]"
        let rows = try JSONDecoder().decode([PatchStatusRow].self, from: Data(arrayJSON.utf8))
        XCTAssertEqual(rows.first?.title, "Chrome")
    }

    // MARK: - Helper

    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Engine/
            .deletingLastPathComponent()   // JamfReportsTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // app/
            .deletingLastPathComponent()   // worktree root
            .appendingPathComponent("tests/fixtures")
    }
}
