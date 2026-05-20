import XCTest
@testable import JamfReports

final class CLISuggesterTests: XCTestCase {

    func testSuggestStaleDaysFromDevices() {
        // Create test devices with varying lastContact days
        let devices = [
            createDevice(daysSinceContact: 1),
            createDevice(daysSinceContact: 3),
            createDevice(daysSinceContact: 7),
            createDevice(daysSinceContact: 14),  // median around here
            createDevice(daysSinceContact: 21),
            createDevice(daysSinceContact: 30),
            createDevice(daysSinceContact: 180), // outlier
        ]

        let suggested = CLISuggester.suggestStaleDays(from: devices)

        // Should be reasonable - between 7 and 90 days
        XCTAssertGreaterThanOrEqual(suggested, 7)
        XCTAssertLessThanOrEqual(suggested, 90)

        // Should be influenced by the distribution, not the outlier
        XCTAssertLessThan(suggested, 100)
    }

    func testSuggestStaleDaysEmptyDevices() {
        let suggested = CLISuggester.suggestStaleDays(from: [])
        XCTAssertEqual(suggested, 30) // Default fallback
    }

    func testSuggestStaleDaysClampedBounds() {
        // All devices very fresh - should clamp to minimum
        let freshDevices = [
            createDevice(daysSinceContact: 1),
            createDevice(daysSinceContact: 2),
            createDevice(daysSinceContact: 3),
        ]
        let freshSuggested = CLISuggester.suggestStaleDays(from: freshDevices)
        XCTAssertGreaterThanOrEqual(freshSuggested, 7)

        // All devices very old - should clamp to maximum
        let staleDevices = [
            createDevice(daysSinceContact: 200),
            createDevice(daysSinceContact: 300),
            createDevice(daysSinceContact: 400),
        ]
        let staleSuggested = CLISuggester.suggestStaleDays(from: staleDevices)
        XCTAssertLessThanOrEqual(staleSuggested, 90)
    }

    func testSuggestEAsForComplianceTemplate() {
        let template = ComplianceTemplate()
        let eas = [
            createEA(name: "STIG Compliance Check", description: "Audit baseline"),
            createEA(name: "FileVault Status", description: "Encryption status"),
            createEA(name: "Random Application", description: "Some app install"),
            createEA(name: "NIST Audit Results", description: "Compliance framework results")
        ]

        let suggested = CLISuggester.suggestEAs(from: eas, template: template)

        let suggestedNames = suggested.map { $0.name ?? "" }
        XCTAssertTrue(suggestedNames.contains("STIG Compliance Check"))
        XCTAssertTrue(suggestedNames.contains("NIST Audit Results"))
        XCTAssertFalse(suggestedNames.contains("Random Application"))
        // FileVault might be included if security keywords overlap
    }

    func testSuggestEAsForSecurityTemplate() {
        let template = SecurityPostureTemplate()
        let eas = [
            createEA(name: "CrowdStrike Falcon Status", description: "Endpoint protection"),
            createEA(name: "Gatekeeper Configuration", description: "Security setting"),
            createEA(name: "Adobe Flash Version", description: "Software version"),
            createEA(name: "Firewall Status", description: "Security protection")
        ]

        let suggested = CLISuggester.suggestEAs(from: eas, template: template)

        let suggestedNames = suggested.map { $0.name ?? "" }
        XCTAssertTrue(suggestedNames.contains("CrowdStrike Falcon Status"))
        XCTAssertTrue(suggestedNames.contains("Gatekeeper Configuration"))
        XCTAssertTrue(suggestedNames.contains("Firewall Status"))
        XCTAssertFalse(suggestedNames.contains("Adobe Flash Version"))
    }

    func testSuggestThresholds() {
        let compliance = ComplianceTemplate()
        let operational = OperationalTemplate()

        let complianceRec = CLISuggester.suggestThresholds(for: compliance)
        XCTAssertEqual(complianceRec.warning, 85)
        XCTAssertEqual(complianceRec.critical, 95)
        XCTAssertEqual(complianceRec.staleDays, 30)

        let operationalRec = CLISuggester.suggestThresholds(for: operational)
        XCTAssertEqual(operationalRec.warning, 80)
        XCTAssertEqual(operationalRec.critical, 90)
        XCTAssertEqual(operationalRec.staleDays, 14)
    }

    // MARK: - Test helpers

    private func createDevice(daysSinceContact: Int) -> DeviceInventoryRecord {
        DeviceInventoryRecord(
            id: "test-\(daysSinceContact)",
            jamfID: nil,
            name: "Test Device",
            serial: "ABC123",
            osVersion: "15.0",
            model: "MacBook",
            user: "",
            email: "",
            department: "",
            building: "",
            site: "",
            ipAddress: "",
            assetTag: "",
            managedState: "",
            lastContact: "",
            lastInventory: "",
            daysSinceContact: daysSinceContact,
            stale: false,
            fileVault: "",
            sip: "",
            firewall: "",
            gatekeeper: "",
            bootstrapToken: "",
            diskUsage: "",
            failedRules: 0,
            patchFailures: [],
            source: "test"
        )
    }

    private func createEA(name: String, description: String) -> ExtensionAttribute {
        // Create a simple EA for testing
        // Note: ExtensionAttribute is Decodable, so we'll use a basic initializer approach
        let jsonData = """
        {
            "id": "\(UUID().uuidString)",
            "name": "\(name)",
            "description": "\(description)",
            "dataType": "STRING",
            "inputType": "TEXT",
            "enabled": true
        }
        """.data(using: .utf8)!

        return try! JSONDecoder().decode(ExtensionAttribute.self, from: jsonData)
    }
}