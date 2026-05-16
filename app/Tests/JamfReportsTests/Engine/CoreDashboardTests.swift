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

    /// Copy fixture dirs but rename them to match the writer's expected subdir name.
    /// Used when the fixture corpus name differs from the jamf-cli command name —
    /// e.g. `compliance-devices-nist-800-53r5-moderate` → `compliance-devices`.
    private func tempDataDir(copyingRenamed map: [(src: String, dst: String)]) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let src = fixturesDir.appendingPathComponent("jamf-cli-data")
        for pair in map {
            let from = src.appendingPathComponent(pair.src, isDirectory: true)
            let to = tmp.appendingPathComponent(pair.dst, isDirectory: true)
            if FileManager.default.fileExists(atPath: from.path) {
                try FileManager.default.copyItem(at: from, to: to)
            }
        }
        return tmp
    }

    /// Seed a single fixture file into a fresh temp dataDir under the writer's
    /// expected subdir name. Use this when a fixture corpus directory contains
    /// both `*_empty.json` and `*_happy.json` so the test deterministically
    /// pins to the happy-path file rather than relying on alphabetical /
    /// mtime ordering of `loadLatestJSON`. `subdir` is the writer-expected
    /// jamf-cli command name; `fixtureRelPath` is path relative to
    /// `tests/fixtures/jamf-cli-data/`.
    private func tempDataDir(seeding subdir: String,
                             fromFixture fixtureRelPath: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-test-\(UUID().uuidString)")
        let subdirURL = tmp.appendingPathComponent(subdir, isDirectory: true)
        try FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)
        let src = fixturesDir.appendingPathComponent("jamf-cli-data/\(fixtureRelPath)")
        if FileManager.default.fileExists(atPath: src.path) {
            try FileManager.default.copyItem(
                at: src,
                to: subdirURL.appendingPathComponent(src.lastPathComponent)
            )
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

    // MARK: - Platform compliance + DDM/Blueprint writers
    //
    // S-11 acceptance: each writer that touches raw `[String: Any]` access has a
    // fixture-backed test that exercises the happy path. The fixture corpus uses
    // baseline-suffixed dir names (e.g. `compliance-devices-nist-800-53r5-moderate`)
    // while writers read from the unsuffixed jamf-cli command name — so these tests
    // copy-with-rename to bridge the two.

    func testWriteComplianceDevices() throws {
        let baseline = "compliance-devices-nist-800-53r5-moderate"
        let dataDir = try tempDataDir(
            seeding: "compliance-devices",
            fromFixture: "\(baseline)/platform_compliance_devices_happy.json"
        )
        guard FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent("compliance-devices").path
        ) else { throw XCTSkip("compliance-devices fixture not available") }

        let dash = makeDashboard(dataDir: dataDir)
        XCTAssertNoThrow(try dash.writeComplianceDevices())
    }

    func testWriteComplianceRules() throws {
        let baseline = "compliance-rules-nist-800-53r5-moderate"
        let dataDir = try tempDataDir(
            seeding: "compliance-rules",
            fromFixture: "\(baseline)/platform_compliance_rules_happy.json"
        )
        guard FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent("compliance-rules").path
        ) else { throw XCTSkip("compliance-rules fixture not available") }

        let dash = makeDashboard(dataDir: dataDir)
        XCTAssertNoThrow(try dash.writeComplianceRules())
    }

    func testWriteDDMStatus() throws {
        let dataDir = try tempDataDir(
            seeding: "ddm-status",
            fromFixture: "ddm-status/platform_ddm_status_happy.json"
        )
        guard FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent("ddm-status").path
        ) else { throw XCTSkip("ddm-status fixture not available") }

        let dash = makeDashboard(dataDir: dataDir)
        XCTAssertNoThrow(try dash.writeDDMStatus())
    }

    func testWriteBlueprintStatus() throws {
        let dataDir = try tempDataDir(
            seeding: "blueprint-status",
            fromFixture: "blueprint-status/platform_blueprint_status_happy.json"
        )
        guard FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent("blueprint-status").path
        ) else { throw XCTSkip("blueprint-status fixture not available") }

        let dash = makeDashboard(dataDir: dataDir)
        XCTAssertNoThrow(try dash.writeBlueprintStatus())
    }

    // MARK: - Protect writers

    /// No `protect-overview` fixture exists in the corpus, so write a small inline
    /// fixture into the temp dataDir for this test only. ProtectOverview is a
    /// loose [{ key: value }] shape — the writer iterates whatever keys are present.
    func testWriteProtectOverview() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let subdir = tmp.appendingPathComponent("protect-overview", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let json = """
        [{"Devices Enrolled":42,"Plans Active":3,"Alerts (Open)":5}]
        """
        try Data(json.utf8).write(to: subdir.appendingPathComponent("protect-overview.json"))

        let dash = makeDashboard(dataDir: tmp)
        XCTAssertNoThrow(try dash.writeProtectOverview())
    }

    /// Protect writer fixture dirs contain both `*_empty.json` and `*_happy.json`.
    /// `loadLatestJSON` picks by mtime, which on freshly-checked-out trees is
    /// effectively alphabetical — so the empty file wins and the writer hits its
    /// guard-empty early-return rather than the loop body. Seeding only the
    /// happy file pins the test to the path it claims to cover.

    func testWriteProtectAlerts() throws {
        let dataDir = try tempDataDir(
            seeding: "protect-alerts",
            fromFixture: "protect-alerts/alerts_happy.json"
        )
        guard FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent("protect-alerts").path
        ) else { throw XCTSkip("protect-alerts fixture not available") }

        let dash = makeDashboard(dataDir: dataDir)
        XCTAssertNoThrow(try dash.writeProtectAlerts())
    }

    func testWriteProtectComputers() throws {
        let dataDir = try tempDataDir(
            seeding: "protect-computers",
            fromFixture: "protect-computers/computers_happy.json"
        )
        guard FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent("protect-computers").path
        ) else { throw XCTSkip("protect-computers fixture not available") }

        let dash = makeDashboard(dataDir: dataDir)
        XCTAssertNoThrow(try dash.writeProtectComputers())
    }

    func testWriteProtectInsights() throws {
        let dataDir = try tempDataDir(
            seeding: "protect-insights",
            fromFixture: "protect-insights/insights_happy.json"
        )
        guard FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent("protect-insights").path
        ) else { throw XCTSkip("protect-insights fixture not available") }

        let dash = makeDashboard(dataDir: dataDir)
        XCTAssertNoThrow(try dash.writeProtectInsights())
    }

    // Negative cases: (1) no fixture dir at all → loadLatestJSON throws
    // .noCachedData and the error propagates out of the writer. (2) fixture
    // present, decodes to [] → writer silently returns and no sheet is
    // appended to the workbook. Both branches are exercised here.

    func testProtectComputersThrowsWhenNoCachedData() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dash = makeDashboard(dataDir: tmp)
        XCTAssertThrowsError(try dash.writeProtectComputers()) { error in
            guard case CoreDashboardError.noCachedData = error else {
                XCTFail("Expected CoreDashboardError.noCachedData, got \(error)")
                return
            }
        }
    }

    /// One representative test for the empty-array silent-return pattern that
    /// repeats across the eight Protect/Platform writers (PR-6 review CONSIDER).
    /// When the JSON file exists and decodes to `[]`, `writeProtectComputers`
    /// must NOT throw and must NOT add a sheet — the workbook stays empty.
    func testProtectComputersSilentReturnOnEmptyArray() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-empty-array-\(UUID().uuidString)")
        let subdir = tmp.appendingPathComponent("protect-computers", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data("[]".utf8).write(to: subdir.appendingPathComponent("empty.json"))

        let workbook = Workbook()
        let dash = CoreDashboard(
            config: ReportConfig(),
            dataDir: tmp,
            workbook: workbook
        )
        XCTAssertNoThrow(try dash.writeProtectComputers(),
                         "Empty array must not raise — silent return is the contract")
        XCTAssertNil(workbook.sheet(named: "Protect Computers"),
                     "Empty array must not produce a sheet; got a stray sheet in the workbook")
    }
}
