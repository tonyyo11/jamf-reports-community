import Foundation
import XCTest
@testable import JamfReports

// MARK: - CoreDashboardTests
// Tests for CoreDashboard write* methods added in the Swift parity pass.
// Each test instantiates a CoreDashboard against a temp dataDir seeded with
// fixture JSON and verifies the sheet is written without throwing.

final class CoreDashboardTests: XCTestCase {

    // MARK: - Helpers

    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Engine/
            .deletingLastPathComponent()   // JamfReportsTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // app/
            .deletingLastPathComponent()   // worktree root
            .appendingPathComponent("tests/fixtures")
    }

    /// Copy a fixture directory into a temp dataDir and return the temp URL.
    private func tempDataDir(copying names: [String]) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
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

    private func makeDashboard(dataDir: URL) -> CoreDashboard {
        CoreDashboard(
            config: ReportConfig(),
            dataDir: dataDir,
            workbook: Workbook()
        )
    }

    // MARK: - Inventory Summary (three-column shape)

    func testWriteInventorySummaryThreeColumns() throws {
        let dataDir = try tempDataDir(copying: ["inventory-summary"])
        guard FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent("inventory-summary").path
        ) else { throw XCTSkip("inventory-summary fixture not available") }

        let dash = makeDashboard(dataDir: dataDir)
        XCTAssertNoThrow(try dash.writeInventorySummary())
    }

    // MARK: - Hardware Models

    func testWriteHardwareModels() throws {
        let dataDir = try tempDataDir(copying: ["inventory-summary"])
        guard FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent("inventory-summary").path
        ) else { throw XCTSkip("inventory-summary fixture not available") }

        let dash = makeDashboard(dataDir: dataDir)
        XCTAssertNoThrow(try dash.writeHardwareModels())
    }

    func testWriteHardwareModelsThrowsWhenEmpty() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dash = makeDashboard(dataDir: tmp)
        XCTAssertThrowsError(try dash.writeHardwareModels()) { error in
            guard case CoreDashboardError.noCachedData = error else {
                XCTFail("Expected CoreDashboardError.noCachedData, got \(error)")
                return
            }
        }
    }

    // MARK: - Mobile Inventory

    func testWriteMobileInventory() throws {
        let dataDir = try tempDataDir(copying: ["mobile-device-inventory-details"])
        guard FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent("mobile-device-inventory-details").path
        ) else { throw XCTSkip("mobile-device-inventory-details fixture not available") }

        let dash = makeDashboard(dataDir: dataDir)
        XCTAssertNoThrow(try dash.writeMobileInventory())
    }

    // MARK: - Mobile Fleet Summary

    func testWriteMobileFleetSummary() throws {
        let dataDir = try tempDataDir(copying: [
            "mobile-device-inventory-details", "classic-ios-profiles",
        ])
        guard FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent("mobile-device-inventory-details").path
        ) else { throw XCTSkip("mobile-device-inventory-details fixture not available") }

        let dash = makeDashboard(dataDir: dataDir)
        XCTAssertNoThrow(try dash.writeMobileFleetSummary())
    }

    func testWriteMobileFleetSummaryThrowsWhenNoData() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dash = makeDashboard(dataDir: tmp)
        XCTAssertThrowsError(try dash.writeMobileFleetSummary())
    }

    // MARK: - Mobile Config Profiles

    func testWriteMobileConfigProfiles() throws {
        let dataDir = try tempDataDir(copying: ["classic-ios-profiles"])
        guard FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent("classic-ios-profiles").path
        ) else { throw XCTSkip("classic-ios-profiles fixture not available") }

        let dash = makeDashboard(dataDir: dataDir)
        XCTAssertNoThrow(try dash.writeMobileConfigProfiles())
    }

    // MARK: - Group Hygiene

    func testWriteGroupHygiene() throws {
        let dataDir = try tempDataDir(copying: ["groups"])
        guard FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent("groups").path
        ) else { throw XCTSkip("groups fixture not available") }

        let dash = makeDashboard(dataDir: dataDir)
        XCTAssertNoThrow(try dash.writeGroupHygiene())
    }

    // MARK: - Smart Groups

    func testWriteSmartGroups() throws {
        let dataDir = try tempDataDir(copying: ["groups"])
        guard FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent("groups").path
        ) else { throw XCTSkip("groups fixture not available") }

        let dash = makeDashboard(dataDir: dataDir)
        XCTAssertNoThrow(try dash.writeSmartGroups())
    }

    // MARK: - Check-in Health

    func testWriteCheckinHealth() throws {
        let dataDir = try tempDataDir(copying: ["device-compliance"])
        guard FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent("device-compliance").path
        ) else { throw XCTSkip("device-compliance fixture not available") }

        let dash = makeDashboard(dataDir: dataDir)
        XCTAssertNoThrow(try dash.writeCheckinHealth())
    }

    // MARK: - Active Devices

    func testWriteActiveDevices() throws {
        let dataDir = try tempDataDir(copying: ["device-compliance"])
        guard FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent("device-compliance").path
        ) else { throw XCTSkip("device-compliance fixture not available") }

        let dash = makeDashboard(dataDir: dataDir)
        XCTAssertNoThrow(try dash.writeActiveDevices())
    }

    // MARK: - Package Lifecycle

    func testWritePackageLifecycle() throws {
        let dataDir = try tempDataDir(copying: ["packages"])
        guard FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent("packages").path
        ) else { throw XCTSkip("packages fixture not available") }

        let dash = makeDashboard(dataDir: dataDir)
        XCTAssertNoThrow(try dash.writePackageLifecycle())
    }

    // MARK: - Environment Stats (no fixture — expected to throw)

    func testWriteEnvironmentStatsThrowsWhenNoFixture() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dash = makeDashboard(dataDir: tmp)
        XCTAssertThrowsError(try dash.writeEnvironmentStats())
    }

    // MARK: - Audit Summary (no fixture — expected to throw)

    func testWriteAuditSummaryThrowsWhenNoFixture() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dash = makeDashboard(dataDir: tmp)
        XCTAssertThrowsError(try dash.writeAuditSummary())
    }

    // MARK: - Sheet plan ordering

    func testSheetPlanContainsAllExpectedSheets() {
        let dash = makeDashboard(dataDir: FileManager.default.temporaryDirectory)
        let names = dash.sheetPlan.map(\.name)
        // New framing sheets prepended; ordering updated per user-research findings.
        let expected = [
            // Framing / exec-priority
            "Cover", "Compliance Posture",
            "Fleet Overview", "Security Posture", "Patch Compliance",
            "Device Compliance", "Audit Summary",
            // Inventory & hardware
            "Inventory Summary", "Hardware Models",
            "Mobile Fleet Summary", "Mobile Inventory",
            // Configuration health
            "Policy Health", "Profile Status", "Mobile Config Profiles", "App Status",
            "Software Installs", "Package Lifecycle",
            "EA Coverage", "EA Definitions", "Environment Stats",
            // Device health
            "Check-in Health", "Active Devices", "Group Hygiene",
            // Update & patch details
            "Patch Failures", "Update Status", "Update Failures", "Smart Groups",
            // Platform / DDM (optional)
            "Compliance Devices", "Compliance Rules", "DDM Status", "Blueprint Status",
            // Protect (optional)
            "Protect Overview", "Protect Alerts", "Protect Computers", "Protect Insights",
        ]
        for name in expected {
            XCTAssertTrue(names.contains(name), "Sheet plan missing: \(name)")
        }
        XCTAssertEqual(names.count, expected.count,
                       "Sheet plan count mismatch. Got: \(names)")
    }

    // MARK: - New decoder types

    func testMobileDeviceInventoryItemDecoding() throws {
        let json = """
        [{"mobileDeviceId":"1","deviceType":"iOS","general":{"displayName":"Test iPad",
        "serialNumber":"ABC123","osVersion":"17.0","managed":true,"supervised":true,
        "lastInventoryUpdateDate":"2024-01-15T10:30:00.000Z",
        "deviceOwnershipType":"Institutional","activationLockEnabled":false,
        "passcodeCompliant":true,"dataProtectionEnabled":true,"jailbreakDetected":"Not Detected"},
        "userAndLocation":{"username":"jdoe","emailAddress":"jdoe@example.com",
        "department":"IT","building":"HQ"}}]
        """
        let items = try JSONDecoder().decode([MobileDeviceInventoryItem].self, from: Data(json.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].mobileDeviceId, "1")
        XCTAssertEqual(items[0].general?.displayName, "Test iPad")
        XCTAssertEqual(items[0].general?.osVersion, "17.0")
        XCTAssertEqual(items[0].general?.managed, true)
        XCTAssertEqual(items[0].userAndLocation?.username, "jdoe")
        XCTAssertEqual(items[0].userAndLocation?.department, "IT")
    }

    func testGroupRowDecoding() throws {
        let json = """
        [{"groupPlatformId":"abc-123","groupJamfProId":"67",
          "groupName":"All Macs","groupType":"COMPUTER","membershipCount":42,"smart":true}]
        """
        let rows = try JSONDecoder().decode([GroupRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].groupName, "All Macs")
        XCTAssertEqual(rows[0].membershipCount, 42)
        XCTAssertEqual(rows[0].smart, true)
    }

    func testPackageRowDecoding() throws {
        let json = """
        [{"id":"1","packageName":"Firefox.pkg","fileName":"Firefox.pkg","notes":"Test","size":10485760}]
        """
        let rows = try JSONDecoder().decode([PackageRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].packageName, "Firefox.pkg")
    }

    func testEnvStatsReportDecoding() throws {
        let json = """
        {"policies":42,"config_profiles":18,"scripts":7,"packages":55,
         "smart_groups_computer":30,"smart_groups_mobile":5,
         "extension_attributes":12,"categories":8}
        """
        let report = try JSONDecoder().decode(EnvStatsReport.self, from: Data(json.utf8))
        XCTAssertEqual(report.policies, 42)
        XCTAssertEqual(report.configProfiles, 18)
        XCTAssertEqual(report.smartGroupsComputer, 30)
        XCTAssertEqual(report.extensionAttributes, 12)
    }

    func testMobileConfigProfileRowDecoding() throws {
        let json = """
        [{"id":1,"name":"WiFi Profile","category":"Network","site":"Main","description":"Corp WiFi"}]
        """
        let rows = try JSONDecoder().decode([MobileConfigProfileRow].self, from: Data(json.utf8))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "WiFi Profile")
        XCTAssertEqual(rows[0].category, "Network")
    }

    // MARK: - Fixture-backed decoder tests

    func testMobileDeviceInventoryFixtureDecoding() throws {
        let fixtureURL = fixturesDir
            .appendingPathComponent("jamf-cli-data/mobile-device-inventory-details")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("Fixture not available")
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: fixtureURL, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        guard let first = files.first else { throw XCTSkip("No JSON files in fixture") }
        let data = try Data(contentsOf: first)
        XCTAssertNoThrow(try JSONDecoder().decode([MobileDeviceInventoryItem].self, from: data))
    }

    func testGroupsFixtureDecoding() throws {
        let fixtureURL = fixturesDir.appendingPathComponent("jamf-cli-data/groups")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("Fixture not available")
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: fixtureURL, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        guard let first = files.first else { throw XCTSkip("No JSON files in fixture") }
        let data = try Data(contentsOf: first)
        let rows = try JSONDecoder().decode([GroupRow].self, from: data)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertNotNil(rows[0].groupName)
    }

    func testPackagesFixtureDecoding() throws {
        let fixtureURL = fixturesDir.appendingPathComponent("jamf-cli-data/packages")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("Fixture not available")
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: fixtureURL, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        guard let first = files.first else { throw XCTSkip("No JSON files in fixture") }
        let data = try Data(contentsOf: first)
        let rows = try JSONDecoder().decode([PackageRow].self, from: data)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertNotNil(rows[0].packageName)
    }
}
