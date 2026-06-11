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

    // MARK: - SecurityDevice (`.device` envelope case)

    func testSecurityDeviceFlattenedFieldsDecoding() throws {
        // v1.7+ flattened per-device control fields onto the section row.
        let json = """
        [{"section":"device","name":"MacBook-001","serial":"ABC123",
          "os_version":"15.4.1","filevault":"Enabled","sip":"Enabled",
          "firewall":true,"gatekeeper":"Enabled"}]
        """
        let items = try JSONDecoder().decode([SecurityReportItem].self, from: Data(json.utf8))
        guard case .device(let d) = items[0] else {
            XCTFail("Expected .device case"); return
        }
        XCTAssertEqual(d.name, "MacBook-001")
        XCTAssertEqual(d.serial, "ABC123")
        XCTAssertEqual(d.osVersion, "15.4.1")
        XCTAssertEqual(d.fileVault, "Enabled")
        XCTAssertEqual(d.firewall, true)
        XCTAssertEqual(d.gatekeeper, "Enabled")
    }

    func testSecurityDeviceLegacyNestedDataDecoding() throws {
        // v1.6 emitted control fields nested under `data: {}` — must still decode.
        let json = """
        [{"section":"device","name":"MacBook-002","serial":"DEF456",
          "data":{"filevault":"Enabled","sip":"Enabled"}}]
        """
        let items = try JSONDecoder().decode([SecurityReportItem].self, from: Data(json.utf8))
        guard case .device(let d) = items[0] else {
            XCTFail("Expected .device case"); return
        }
        XCTAssertEqual(d.name, "MacBook-002")
        XCTAssertNil(d.osVersion)
        XCTAssertNotNil(d.data)
        XCTAssertEqual(d.data?["filevault"]?.stringValue, "Enabled")
    }

    // MARK: - PolicyStatusReport / Summary / Finding

    func testPolicyStatusReportDecoding() throws {
        let json = """
        [{"summary":{"total_policies":42,"enabled":40,"disabled":2,
          "config_findings":3,"warnings":1,"info":2},
          "config_findings":[
            {"severity":"warning","policy":"Onboarding","policy_id":"10",
             "check":"no_scope","detail":"No targets in scope"}]}]
        """
        let reports = try JSONDecoder().decode([PolicyStatusReport].self, from: Data(json.utf8))
        XCTAssertEqual(reports.count, 1)
        let r = reports[0]
        XCTAssertEqual(r.summary.totalPolicies, 42)
        XCTAssertEqual(r.summary.enabled, 40)
        XCTAssertEqual(r.summary.configFindings, 3)
        XCTAssertEqual(r.configFindings.count, 1)
        XCTAssertEqual(r.configFindings[0].severity, "warning")
        XCTAssertEqual(r.configFindings[0].policyId, "10")
        XCTAssertEqual(r.configFindings[0].check, "no_scope")
    }

    func testPolicyStatusFixtureDecodesWithoutError() throws {
        let fixtureURL = fixturesDir
            .appendingPathComponent("jamf-cli-data/policy-status/policy-status.json")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("Fixture not available")
        }
        let data = try Data(contentsOf: fixtureURL)
        XCTAssertNoThrow(
            try JSONDecoder().decode([PolicyStatusReport].self, from: data)
        )
    }

    // MARK: - PatchFailureRow

    func testPatchFailureRowDecoding() throws {
        let json = """
        [{"policy":"Firefox 130.0","policy_id":"42","device":"MacBook-001",
          "device_id":"123","status_date":"2026-04-01","attempt":3,
          "last_action":"Retrying","serial":"ABC123",
          "os_version":"15.7.3","username":"jdoe"}]
        """
        let rows = try JSONDecoder().decode([PatchFailureRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows[0].policy, "Firefox 130.0")
        XCTAssertEqual(rows[0].policyId, "42")
        XCTAssertEqual(rows[0].deviceId, "123")
        XCTAssertEqual(rows[0].statusDate, "2026-04-01")
        XCTAssertEqual(rows[0].attempt, 3)
        XCTAssertEqual(rows[0].lastAction, "Retrying")
        XCTAssertEqual(rows[0].osVersion, "15.7.3")
        XCTAssertEqual(rows[0].id, "123-42-3")
    }

    func testPatchFailureFixtureDecodesWithoutError() throws {
        // Locked in via PR-5 fixture synthesis: the file holds PatchFailureRow
        // entries with policy/policy_id/device/device_id/etc. Replaced the
        // earlier wrong-shape (PatchStatusRow) fixture.
        let fixtureURL = fixturesDir
            .appendingPathComponent("jamf-cli-data/patch-device-failures/patch-device-failures.json")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("Fixture not available")
        }
        let data = try Data(contentsOf: fixtureURL)
        let rows = try JSONDecoder().decode([PatchFailureRow].self, from: data)
        XCTAssertGreaterThan(rows.count, 0,
                             "Synthesised patch-device-failures fixture must contain at least one row")
        // Spot-check that synthetic markers are present (guards against an
        // accidental swap with real-tenant data).
        XCTAssertTrue(rows.allSatisfy { $0.serial.hasPrefix("TEST-") },
                      "Every failure row must carry a TEST- serial marker")
    }

    // MARK: - UpdateFailuresReport / ErrorDevice / FailedPlan

    func testUpdateFailuresReportDecoding() throws {
        let json = """
        [{"total":2,
          "status_summary":[{"status":"FAILED","count":2}],
          "error_devices":[{"name":"MacBook-001","serial":"ABC123",
            "device_type":"COMPUTER","os_version":"15.7","username":"jdoe",
            "status":"DOWNLOAD_FAILED","product_key":"MACOS_15_7",
            "updated":"2026-04-01T12:00:00Z"}],
          "plan_total":1,
          "plan_state_summary":[{"state":"Failed","count":1}],
          "failed_plans":[{"name":"MacBook-001","serial":"ABC123",
            "device_type":"COMPUTER","os_version":"15.7","username":"jdoe",
            "state":"Failed","action":"DOWNLOAD","version":"15.7",
            "error":"NetworkError","last_event":"2026-04-01T12:05:00Z"}]}]
        """
        let reports = try JSONDecoder().decode([UpdateFailuresReport].self, from: Data(json.utf8))
        XCTAssertEqual(reports.count, 1)
        let r = reports[0]
        XCTAssertEqual(r.total, 2)
        XCTAssertEqual(r.errorDevices.count, 1)
        XCTAssertEqual(r.errorDevices[0].name, "MacBook-001")
        XCTAssertEqual(r.errorDevices[0].deviceType, "COMPUTER")
        XCTAssertEqual(r.errorDevices[0].productKey, "MACOS_15_7")
        XCTAssertEqual(r.failedPlans.count, 1)
        XCTAssertEqual(r.failedPlans[0].state, "Failed")
        XCTAssertEqual(r.failedPlans[0].error, "NetworkError")
        XCTAssertEqual(r.failedPlans[0].lastEvent, "2026-04-01T12:05:00Z")
    }

    func testUpdateFailuresFixtureDecodesWithoutError() throws {
        // Locked in via PR-5 fixture synthesis: replaces the earlier 503
        // error-envelope fixture with a valid UpdateFailuresReport array
        // containing populated error_devices and failed_plans.
        let fixtureURL = fixturesDir
            .appendingPathComponent("jamf-cli-data/update-device-failures/update-device-failures.json")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("Fixture not available")
        }
        let data = try Data(contentsOf: fixtureURL)
        let reports = try JSONDecoder().decode([UpdateFailuresReport].self, from: data)
        XCTAssertEqual(reports.count, 1,
                       "update-device-failures fixture must be an array with a single report element")
        let report = reports[0]
        XCTAssertGreaterThan(report.errorDevices.count, 0,
                             "Fixture must include populated error_devices to exercise the writer")
        XCTAssertGreaterThan(report.failedPlans.count, 0,
                             "Fixture must include populated failed_plans to exercise the writer")
        XCTAssertTrue(report.errorDevices.allSatisfy { $0.serial.hasPrefix("TEST-") },
                      "Every error device must carry a TEST- serial marker")
        XCTAssertTrue(report.failedPlans.allSatisfy { $0.serial.hasPrefix("TEST-") },
                      "Every failed plan must carry a TEST- serial marker")
    }

    // MARK: - InventorySummaryRow

    func testInventorySummaryRowDecoding() throws {
        let json = """
        [{"os_version":"macOS 15.4.1","count":42},
         {"os_version":"macOS 14.7","count":7}]
        """
        let rows = try JSONDecoder().decode([InventorySummaryRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].osVersion, "macOS 15.4.1")
        XCTAssertEqual(rows[0].count, 42)
    }

    // MARK: - DeviceComplianceRow

    func testDeviceComplianceRowDecoding() throws {
        let json = """
        [{"name":"MacBook-001","serial":"ABC123","managed":true,
          "stale":false,"days_since_checkin":3}]
        """
        let rows = try JSONDecoder().decode([DeviceComplianceRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows[0].name, "MacBook-001")
        XCTAssertEqual(rows[0].serial, "ABC123")
        XCTAssertEqual(rows[0].managed, true)
        XCTAssertEqual(rows[0].stale, false)
        XCTAssertEqual(rows[0].daysSinceCheckin, 3)
    }

    func testDeviceComplianceRowOptionalFields() throws {
        // All fields are optional — empty object must still decode.
        let json = "[{}]"
        let rows = try JSONDecoder().decode([DeviceComplianceRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].name)
        XCTAssertNil(rows[0].daysSinceCheckin)
    }

    // MARK: - EAResultRow

    func testEAResultRowDecoding() throws {
        // value is AnyCodable — both strings and booleans must coalesce.
        let json = """
        [{"computer_id":"101","computer_name":"MacBook-001","serial":"ABC123",
          "ea_id":"5","ea_name":"FileVault Status","value":"Encrypted"},
         {"computer_id":"102","ea_id":"5","value":true}]
        """
        let rows = try JSONDecoder().decode([EAResultRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].computerName, "MacBook-001")
        XCTAssertEqual(rows[0].eaId, "5")
        XCTAssertEqual(rows[0].value?.stringValue, "Encrypted")
        XCTAssertEqual(rows[1].value?.boolValue, true)
    }

    // MARK: - SoftwareInstallRow

    func testSoftwareInstallRowDecoding() throws {
        let json = """
        [{"name":"Microsoft Word","version":"16.84","count":42},
         {"name":"Chrome","count":15}]
        """
        let rows = try JSONDecoder().decode([SoftwareInstallRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows[0].name, "Microsoft Word")
        XCTAssertEqual(rows[0].version, "16.84")
        XCTAssertEqual(rows[0].count, 42)
        XCTAssertNil(rows[1].version)
    }

    // MARK: - AppStatusRow

    func testAppStatusRowDecoding() throws {
        let json = """
        [{"name":"Slack","version":"4.36.0","installed":50,"managed":48,
          "total":50,"errors":2}]
        """
        let rows = try JSONDecoder().decode([AppStatusRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows[0].name, "Slack")
        XCTAssertEqual(rows[0].installed, 50)
        XCTAssertEqual(rows[0].managed, 48)
        XCTAssertEqual(rows[0].errors, 2)
    }

    // MARK: - SmartGroupRow

    func testSmartGroupRowDecodesIntAndStringIds() throws {
        // id can be Int or String depending on endpoint — AnyCodable accepts both.
        let json = """
        [{"id":42,"name":"All Encrypted","membershipCount":100,"smart":true},
         {"id":"abc-7","name":"Stale Devices","membershipCount":"5","smart":false}]
        """
        let rows = try JSONDecoder().decode([SmartGroupRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].id?.intValue, 42)
        XCTAssertEqual(rows[0].name, "All Encrypted")
        XCTAssertEqual(rows[0].membershipCount?.intValue, 100)
        XCTAssertEqual(rows[0].smart, true)
        XCTAssertEqual(rows[1].id?.stringValue, "abc-7")
        XCTAssertEqual(rows[1].membershipCount?.stringValue, "5")
    }

    // MARK: - ProfileStatusEnvelope

    /// Real `pro report profile-status` shape — the pre-2.2.2 decoder targeted
    /// a flat shape jamf-cli never emits, which decoded the envelope as one
    /// all-nil row and crashed the Profiles table (#185).
    func testProfileStatusEnvelopeDecoding() throws {
        let json = """
        [{"summary":{"total_errors":12,"unique_profiles":2,"unique_devices":9,"days":30,
                     "devices_high_failure":1,"devices_high_pending":0},
          "failures":[{"device_type":"Computer","name":"WiFi Profile","id":"7",
                       "errors":10,"devices":8,"last_error":"2026-06-10",
                       "top_error":"Payload could not be installed"},
                      {"device_type":"Mobile Device","name":"VPN","id":3,
                       "errors":2,"devices":1,"last_error":"2026-06-09","top_error":"Timeout"}],
          "device_failures":[],"device_pending":[]}]
        """
        let envelopes = try JSONDecoder().decode([ProfileStatusEnvelope].self, from: Data(json.utf8))
        let envelope = try XCTUnwrap(envelopes.first)
        XCTAssertEqual(envelope.summary?.totalErrors, 12)
        XCTAssertEqual(envelope.summary?.uniqueProfiles, 2)
        XCTAssertEqual(envelope.summary?.uniqueDevices, 9)
        XCTAssertEqual(envelope.summary?.days, 30)
        let failures = try XCTUnwrap(envelope.failures)
        XCTAssertEqual(failures.count, 2)
        XCTAssertEqual(failures[0].name, "WiFi Profile")
        XCTAssertEqual(failures[0].profileId?.stringValue, "7")
        XCTAssertEqual(failures[0].errors?.intValue, 10)
        XCTAssertEqual(failures[1].profileId?.stringValue, "3", "id arrives as Int or String")
        XCTAssertEqual(failures[1].deviceType, "Mobile Device")
    }

    // MARK: - CheckinStatusRow

    func testCheckinStatusRowDecoding() throws {
        let json = """
        [{"name":"MacBook-001","serial":"ABC123",
          "days_since_checkin":12,"status":"warning"}]
        """
        let rows = try JSONDecoder().decode([CheckinStatusRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows[0].name, "MacBook-001")
        XCTAssertEqual(rows[0].daysSinceCheckin, 12)
        XCTAssertEqual(rows[0].status, "warning")
    }

    // MARK: - HardwareModelRow

    func testHardwareModelRowDecoding() throws {
        let json = """
        [{"model":"MacBookPro18,3","count":42,"pct":"60%"},
         {"model":"Mac15,12","count":28}]
        """
        let rows = try JSONDecoder().decode([HardwareModelRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows[0].model, "MacBookPro18,3")
        XCTAssertEqual(rows[0].count, 42)
        XCTAssertEqual(rows[0].pct, "60%")
        XCTAssertNil(rows[1].pct)
    }

    // MARK: - AuditItem

    func testAuditItemDecoding() throws {
        let json = """
        [{"section":"Inventory","check":"Stale Devices","severity":"warning",
          "status":"fail","detail":"5 stale devices found",
          "recommendation":"Review and retire","resource":"computers","value":5}]
        """
        let rows = try JSONDecoder().decode([AuditItem].self, from: Data(json.utf8))
        XCTAssertEqual(rows[0].section, "Inventory")
        XCTAssertEqual(rows[0].check, "Stale Devices")
        XCTAssertEqual(rows[0].severity, "warning")
        XCTAssertEqual(rows[0].recommendation, "Review and retire")
        XCTAssertEqual(rows[0].value?.intValue, 5)
    }

    // MARK: - GroupAnalysisRow

    func testGroupAnalysisRowDecoding() throws {
        let json = """
        [{"groupName":"All Macs","groupType":"COMPUTER",
          "membershipCount":42,"smart":true,"unused":false}]
        """
        let rows = try JSONDecoder().decode([GroupAnalysisRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows[0].groupName?.stringValue, "All Macs")
        XCTAssertEqual(rows[0].groupType?.stringValue, "COMPUTER")
        XCTAssertEqual(rows[0].membershipCount?.intValue, 42)
        XCTAssertEqual(rows[0].smart, true)
        XCTAssertEqual(rows[0].unused, false)
    }

    // MARK: - MobileDeviceListRow

    func testMobileDeviceListRowDecoding() throws {
        let json = """
        [{"id":"1","name":"iPad-001","model":"iPad Pro",
          "serialNumber":"SN12345","username":"jdoe","type":"iPadOS"}]
        """
        let rows = try JSONDecoder().decode([MobileDeviceListRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows[0].id, "1")
        XCTAssertEqual(rows[0].name, "iPad-001")
        XCTAssertEqual(rows[0].model, "iPad Pro")
        XCTAssertEqual(rows[0].serialNumber, "SN12345")
        XCTAssertEqual(rows[0].type, "iPadOS")
    }

    // MARK: - ComplianceDeviceRow

    func testComplianceDeviceRowDecoding() throws {
        let json = """
        [{"device":"MacBook-001","deviceId":"101","rulesFailed":0,
          "rulesPassed":12,"compliance":"100%"}]
        """
        let rows = try JSONDecoder().decode([ComplianceDeviceRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows[0].device, "MacBook-001")
        XCTAssertEqual(rows[0].deviceId, "101")
        XCTAssertEqual(rows[0].rulesFailed, 0)
        XCTAssertEqual(rows[0].rulesPassed, 12)
        XCTAssertEqual(rows[0].compliance, "100%")
    }

    // MARK: - ComplianceRuleRow

    func testComplianceRuleRowDecoding() throws {
        let json = """
        [{"rule":"Require FileVault","passed":48,"failed":2,
          "unknown":0,"devices":50,"passRate":"96%"}]
        """
        let rows = try JSONDecoder().decode([ComplianceRuleRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows[0].rule, "Require FileVault")
        XCTAssertEqual(rows[0].passed, 48)
        XCTAssertEqual(rows[0].failed, 2)
        XCTAssertEqual(rows[0].devices, 50)
        XCTAssertEqual(rows[0].passRate, "96%")
    }

    // MARK: - DDMStatusRow

    func testDDMStatusRowDecoding() throws {
        let json = """
        [{"source":"Identity","type":"declaration","declarations":3,
          "devices":50,"successful":48,"unsuccessful":2}]
        """
        let rows = try JSONDecoder().decode([DDMStatusRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows[0].source, "Identity")
        XCTAssertEqual(rows[0].type, "declaration")
        XCTAssertEqual(rows[0].declarations, 3)
        XCTAssertEqual(rows[0].successful, 48)
        XCTAssertEqual(rows[0].unsuccessful, 2)
    }

    // MARK: - BlueprintStatusRow

    func testBlueprintStatusRowDecoding() throws {
        let json = """
        [{"name":"Core Mac Blueprint","state":"Active","scope":50,
          "steps":4,"failed":0,"pending":2,"succeeded":48}]
        """
        let rows = try JSONDecoder().decode([BlueprintStatusRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows[0].name, "Core Mac Blueprint")
        XCTAssertEqual(rows[0].state, "Active")
        XCTAssertEqual(rows[0].scope, 50)
        XCTAssertEqual(rows[0].failed, 0)
        XCTAssertEqual(rows[0].succeeded, 48)
    }

    // MARK: - ProtectOverviewItem

    func testProtectOverviewItemDynamicFieldsDecoding() throws {
        // ProtectOverviewItem reads arbitrary keys via DynamicCodingKey.
        let json = """
        [{"resource":"Devices Enrolled","value":42,"trend":"up"}]
        """
        let items = try JSONDecoder().decode([ProtectOverviewItem].self, from: Data(json.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].value?.intValue, 42)
        XCTAssertEqual(items[0].extraFields["resource"]?.stringValue, "Devices Enrolled")
        XCTAssertEqual(items[0].extraFields["trend"]?.stringValue, "up")
    }

    // MARK: - ProtectAlertRow

    func testProtectAlertRowDecoding() throws {
        let json = """
        [{"uuid":"alert-1","created":"2026-05-01T08:00:00Z",
          "severity":"high","status":"New","eventType":"ProcessExecution",
          "hostName":"lab-mac-01","serial":"ABC123"}]
        """
        let rows = try JSONDecoder().decode([ProtectAlertRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows[0].uuid, "alert-1")
        XCTAssertEqual(rows[0].created, "2026-05-01T08:00:00Z")
        XCTAssertEqual(rows[0].severity, "high")
        XCTAssertEqual(rows[0].eventType, "ProcessExecution")
        XCTAssertEqual(rows[0].hostName, "lab-mac-01")
        XCTAssertEqual(rows[0].serial, "ABC123")
    }

    func testProtectAlertFixtureDecodesWithoutError() throws {
        let fixtureURL = fixturesDir
            .appendingPathComponent("jamf-cli-data/protect-alerts/alerts_happy.json")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("Fixture not available")
        }
        let data = try Data(contentsOf: fixtureURL)
        XCTAssertNoThrow(
            try JSONDecoder().decode([ProtectAlertRow].self, from: data)
        )
    }

    // MARK: - ProtectComputerRow

    func testProtectComputerRowExtractsNestedPlanName() throws {
        // `plan` is a nested object {id, name}; decoder pulls name into planName.
        let json = """
        [{"uuid":"comp-1","hostName":"lab-mac-01","serial":"ABC123",
          "modelName":"MacBookPro18,3","osString":"15.4.1",
          "plan":{"id":"p1","name":"Engineering Plan"},
          "webProtectionActive":true,"fullDiskAccess":false,
          "connectionStatus":"Connected","lastConnection":"2026-05-01T08:00:00Z",
          "insightsStatsPass":18,"insightsStatsFail":2}]
        """
        let rows = try JSONDecoder().decode([ProtectComputerRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows[0].uuid, "comp-1")
        XCTAssertEqual(rows[0].hostName, "lab-mac-01")
        XCTAssertEqual(rows[0].planName, "Engineering Plan")
        XCTAssertEqual(rows[0].webProtectionActive, true)
        XCTAssertEqual(rows[0].fullDiskAccess, false)
        XCTAssertEqual(rows[0].insightsStatsPass, 18)
    }

    func testProtectComputerRowNilPlanWhenMissing() throws {
        // No `plan` key — planName must be nil rather than crashing.
        let json = """
        [{"uuid":"comp-2","hostName":"lab-mac-02","serial":"DEF456"}]
        """
        let rows = try JSONDecoder().decode([ProtectComputerRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows[0].uuid, "comp-2")
        XCTAssertNil(rows[0].planName)
    }

    // MARK: - ProtectInsightRow

    func testProtectInsightRowDecoding() throws {
        let json = """
        [{"uuid":"ins-1","label":"FileVault Coverage",
          "section":"Encryption","description":"Devices with FV enabled",
          "totalPass":48,"totalFail":2,"enabled":true}]
        """
        let rows = try JSONDecoder().decode([ProtectInsightRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows[0].uuid, "ins-1")
        XCTAssertEqual(rows[0].label, "FileVault Coverage")
        XCTAssertEqual(rows[0].section, "Encryption")
        XCTAssertEqual(rows[0].totalPass, 48)
        XCTAssertEqual(rows[0].totalFail, 2)
        XCTAssertEqual(rows[0].enabled, true)
    }

    // MARK: - AdvancedMobileSearchEnvelope / AdvancedMobileSearchRow

    func testAdvancedMobileSearchEnvelopeDecoding() throws {
        let json = """
        {
          "totalCount": 2,
          "results": [
            {
              "id": "211",
              "name": "iPads – No Passcode",
              "criteria": [
                {"name": "Model", "priority": 0, "andOr": "and", "searchType": "like",
                 "value": "iPad", "openingParen": false, "closingParen": false}
              ],
              "displayFields": ["Device Name", "Serial Number"],
              "siteId": "-1"
            },
            {
              "id": "212",
              "name": "iPhones – Unmanaged",
              "criteria": [],
              "displayFields": [],
              "siteId": "3"
            }
          ]
        }
        """
        let envelope = try JSONDecoder().decode(
            AdvancedMobileSearchEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(envelope.totalCount, 2)
        XCTAssertEqual(envelope.results.count, 2)
        XCTAssertEqual(envelope.results[0].id, "211")
        XCTAssertEqual(envelope.results[0].name, "iPads – No Passcode")
        XCTAssertEqual(envelope.results[0].criteria?.count, 1)
        XCTAssertEqual(envelope.results[0].criteria?[0].name, "Model")
        XCTAssertEqual(envelope.results[0].criteria?[0].value, "iPad")
        XCTAssertEqual(envelope.results[0].displayFields?.count, 2)
        XCTAssertEqual(envelope.results[0].siteId, "-1")
        XCTAssertEqual(envelope.results[1].id, "212")
        XCTAssertEqual(envelope.results[1].criteria?.count, 0)
    }

    func testAdvancedMobileSearchEnvelopeEmptyResults() throws {
        let json = #"{"totalCount": 0, "results": []}"#
        let envelope = try JSONDecoder().decode(
            AdvancedMobileSearchEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(envelope.totalCount, 0)
        XCTAssertTrue(envelope.results.isEmpty)
    }

    func testAdvancedMobileSearchRowMissingOptionalFields() throws {
        // Minimal row — only name present. Should decode without throwing.
        let json = #"{"totalCount": 1, "results": [{"name": "Minimal Search"}]}"#
        let envelope = try JSONDecoder().decode(
            AdvancedMobileSearchEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(envelope.results[0].name, "Minimal Search")
        XCTAssertNil(envelope.results[0].id)
        XCTAssertNil(envelope.results[0].criteria)
        XCTAssertNil(envelope.results[0].displayFields)
        XCTAssertNil(envelope.results[0].siteId)
    }

    // MARK: - ClassicGroupRow

    func testClassicGroupRowDecodingSmartGroup() throws {
        let json = """
        [{"id": 42, "is_smart": true, "name": "Smart – All Managed Macs"}]
        """
        let groups = try JSONDecoder().decode([ClassicGroupRow].self, from: Data(json.utf8))
        XCTAssertEqual(groups[0].id, 42)
        XCTAssertTrue(groups[0].isSmart)
        XCTAssertEqual(groups[0].name, "Smart – All Managed Macs")
    }

    func testClassicGroupRowDecodingStaticGroup() throws {
        let json = """
        [{"id": 7, "is_smart": false, "name": "Static – Lab Devices"}]
        """
        let groups = try JSONDecoder().decode([ClassicGroupRow].self, from: Data(json.utf8))
        XCTAssertEqual(groups[0].id, 7)
        XCTAssertFalse(groups[0].isSmart)
        XCTAssertEqual(groups[0].name, "Static – Lab Devices")
    }

    func testClassicGroupRowMissingIsSmartDefaultsToFalse() throws {
        // Missing is_smart must not throw — defaults to false (static group).
        let json = #"[{"id": 99, "name": "Unnamed Group"}]"#
        let groups = try JSONDecoder().decode([ClassicGroupRow].self, from: Data(json.utf8))
        XCTAssertEqual(groups[0].id, 99)
        XCTAssertFalse(groups[0].isSmart, "missing is_smart must default to false")
    }

    func testClassicGroupRowEmptyArray() throws {
        let groups = try JSONDecoder().decode([ClassicGroupRow].self, from: Data("[]".utf8))
        XCTAssertTrue(groups.isEmpty)
    }

    func testClassicGroupRowMixedSmartStatic() throws {
        let json = """
        [
          {"id": 1, "is_smart": true,  "name": "Smart Group A"},
          {"id": 2, "is_smart": false, "name": "Static Group B"},
          {"id": 3,                    "name": "No Flag Group"}
        ]
        """
        let groups = try JSONDecoder().decode([ClassicGroupRow].self, from: Data(json.utf8))
        XCTAssertEqual(groups.count, 3)
        XCTAssertTrue(groups[0].isSmart)
        XCTAssertFalse(groups[1].isSmart)
        XCTAssertFalse(groups[2].isSmart, "absent flag must default to false")
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

    // MARK: - Negative key-mapping (Epic #102, item #5)
    //
    // Every test above asserts decoded values for valid JSON. None assert that
    // a *required* key's absence fails the decode — so silently changing a
    // required field to optional, or breaking a CodingKey mapping, would pass
    // the whole suite. These lift the `keyNotFound` case into explicit
    // `XCTAssertThrowsError` for a representative plain key and snake_case-
    // mapped key on `UpdateStatusReport` (`total` non-optional Int;
    // `status_summary` mapped via `CodingKeys.statusSummary`).

    func testUpdateStatusReportMissingTotalThrowsKeyNotFound() {
        // `total` is a non-optional Int. JSON without it must throw, not
        // decode to a default — a regression making it optional fails here.
        let json = #"[{"status_summary":[]}]"#
        XCTAssertThrowsError(
            try JSONDecoder().decode([UpdateStatusReport].self, from: Data(json.utf8))
        ) { error in
            guard case DecodingError.keyNotFound(let key, _) = error else {
                return XCTFail("Expected DecodingError.keyNotFound, got \(error)")
            }
            XCTAssertEqual(key.stringValue, "total",
                           "The missing key must be reported as `total`")
        }
    }

    func testUpdateStatusReportMissingStatusSummaryThrowsKeyNotFound() {
        // Guards the snake_case CodingKey: `status_summary` is required and
        // mapped from `CodingKeys.statusSummary`. A broken mapping would throw
        // keyNotFound for a *different* key name than "status_summary".
        let json = #"[{"total":5}]"#
        XCTAssertThrowsError(
            try JSONDecoder().decode([UpdateStatusReport].self, from: Data(json.utf8))
        ) { error in
            guard case DecodingError.keyNotFound(let key, _) = error else {
                return XCTFail("Expected DecodingError.keyNotFound, got \(error)")
            }
            XCTAssertEqual(key.stringValue, "status_summary",
                           "The missing key must be reported under its JSON name")
        }
    }
}
