import Foundation
import XCTest
@testable import JamfReports

/// A Jamf School, Protect-only or mobile-only workspace has no `computers` snapshot, so it gets
/// no Management card, no Management filter match and no workbook tab.
final class ManagementProductGateTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    /// A data folder holding one snapshot kind and nothing else.
    private func dataDir(holding kind: String) throws -> URL {
        let root = GoldenFleetWorkspace.freshRoot()
        roots.append(root)
        let dir = root.appendingPathComponent("data", isDirectory: true)
        try GoldenFleetWorkspace.writeSnapshot(
            kind: kind, dataDir: dir, at: GoldenFleetClock.anchorNoon(),
            rows: [["name": "x", "hostname": "x", "serialNumber": "S1"]])
        return dir
    }

    private func assertNothingManagement(kind: String) throws {
        let dir = try dataDir(holding: kind)
        // No Mac was read from it: the inventory is empty and the reader had nothing to warn of.
        let inventory = DeviceInventorySnapshot.empty
        XCTAssertNil(
            ManagementCard.load(dataDir: dir, inventory: inventory, warningDays: 90), kind)
        let dash = CoreDashboard(
            config: try ConfigLoader.loadFromString(""), dataDir: dir, workbook: Workbook())
        XCTAssertThrowsError(try dash.writeManagementHealth(), kind)
        XCTAssertNil(dash.workbook.sheet(named: "Management Health"), kind)
        let rows = DevicesView.buildRows(
            devices: inventory.devices, query: "", osFilter: nil, filter: .management,
            sortOrder: [], policy: .default, staleRule: StaleRule(days: 30), contactGapDays: 14,
            needsManagementAttention: { _ in true },
            searchableText: { $0.searchableText },
            risk: { device in
                RiskScoringService.risk(
                    for: device, agentCheck: nil, policy: .default,
                    staleRule: StaleRule(days: 30))
            })
        XCTAssertTrue(rows.isEmpty, kind)
    }

    func testAJamfSchoolWorkspaceHasNoManagementSurface() throws {
        try assertNothingManagement(kind: "school-devices")
    }

    func testAProtectOnlyWorkspaceHasNoManagementSurface() throws {
        try assertNothingManagement(kind: "protect-computers")
    }

    func testAMobileOnlyWorkspaceHasNoManagementSurface() throws {
        try assertNothingManagement(kind: "mobile-devices-list")
    }

    func testManagementFilterFindsNothingAmongMacsWithoutFacts() {
        var record = DeviceInventoryRecord.empty(id: "a", source: "test")
        record.managedState = "Managed"
        let health = ManagementHealth(
            records: [record], rule: StaleRule(days: 30), now: Date())
        XCTAssertFalse(health.judgedAnything)
        XCTAssertFalse(health.needsAttention(record))
    }

    func testLoadReadsTheEnrollmentSnapshotFromAnExplicitDataFolder() throws {
        let root = GoldenFleetWorkspace.freshRoot()
        roots.append(root)
        let dir = root.appendingPathComponent("data", isDirectory: true)
        let now = Date()
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: 10, to: now) ?? now
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let text = String(
            format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "device-enrollment-instances", dataDir: dir, at: GoldenFleetClock.anchorNoon(),
            rows: [["name": "Placeholder", "tokenExpirationDate": text]])
        let card = ManagementCard.load(
            dataDir: dir, inventory: .empty, warningDays: 90, now: now)
        XCTAssertEqual(card?.tokens.count, 1)
        XCTAssertEqual(card?.tokens.first?.tone, .warning)
        XCTAssertNil(ManagementCard.load(dataDir: dir, inventory: .empty, warningDays: 90,
                                         now: now)?.inventoryNote)
        // An unresolved folder reads as could not be read, never as not collected.
        XCTAssertEqual(
            ManagementCard.load(dataDir: nil, inventory: .empty, warningDays: 90)?.tokenNote,
            "Automated Device Enrollment token: could not be read")
    }
}
