import XCTest
import SwiftUI
@testable import JamfReports

/// Tests for the StaleDeviceService and OutreachView. Confirms the service can
/// bucket devices correctly by days-since-checkin tiers and that the view
/// instantiates without crashing in both demo and live modes.
@MainActor
final class StaleDeviceServiceTests: XCTestCase {

    func testOutreachViewInstantiatesInDemoMode() throws {
        let workspace = WorkspaceStore()
        workspace.profile = "test"
        workspace.demoMode = true

        _ = OutreachView().environment(workspace)
    }

    func testOutreachViewInstantiatesOutsideDemoMode() throws {
        let workspace = WorkspaceStore()
        workspace.profile = "test"
        workspace.demoMode = false

        _ = OutreachView().environment(workspace)
    }

    // MARK: - Tier boundary tests

    func testTierBoundaries() throws {
        XCTAssertEqual(StaleDeviceService.Tier.tier(for: 0), .recent)
        XCTAssertEqual(StaleDeviceService.Tier.tier(for: 30), .recent)
        XCTAssertEqual(StaleDeviceService.Tier.tier(for: 31), .offline)
        XCTAssertEqual(StaleDeviceService.Tier.tier(for: 90), .offline)
        XCTAssertEqual(StaleDeviceService.Tier.tier(for: 91), .inactive)
        XCTAssertEqual(StaleDeviceService.Tier.tier(for: 180), .inactive)
        XCTAssertEqual(StaleDeviceService.Tier.tier(for: 181), .dormant)
        XCTAssertEqual(StaleDeviceService.Tier.tier(for: nil), .recent, "nil days should default to recent")
    }

    func testTierContains() throws {
        let recent = StaleDeviceService.Tier.recent
        let offline = StaleDeviceService.Tier.offline
        let inactive = StaleDeviceService.Tier.inactive
        let dormant = StaleDeviceService.Tier.dormant

        XCTAssertTrue(recent.contains(0))
        XCTAssertTrue(recent.contains(30))
        XCTAssertFalse(recent.contains(31))

        XCTAssertFalse(offline.contains(30))
        XCTAssertTrue(offline.contains(31))
        XCTAssertTrue(offline.contains(90))
        XCTAssertFalse(offline.contains(91))

        XCTAssertFalse(inactive.contains(90))
        XCTAssertTrue(inactive.contains(91))
        XCTAssertTrue(inactive.contains(180))
        XCTAssertFalse(inactive.contains(181))

        XCTAssertFalse(dormant.contains(180))
        XCTAssertTrue(dormant.contains(181))
        XCTAssertTrue(dormant.contains(365))
    }

    // MARK: - Service logic tests

    func testSnapshotFromRecordsPartitionsCorrectly() throws {
        // Create test records with known daysSinceContact values
        var records: [DeviceInventoryRecord] = []

        // 2 recent (0-30 days)
        var recent1 = DeviceInventoryRecord.empty(id: "recent-1", source: "test")
        recent1.name = "Recent-1"
        recent1.daysSinceContact = 15
        records.append(recent1)

        var recent2 = DeviceInventoryRecord.empty(id: "recent-2", source: "test")
        recent2.name = "Recent-2"
        recent2.daysSinceContact = nil  // nil should go to recent
        records.append(recent2)

        // 2 offline (31-90 days)
        var offline1 = DeviceInventoryRecord.empty(id: "offline-1", source: "test")
        offline1.name = "Offline-1"
        offline1.daysSinceContact = 45
        records.append(offline1)

        var offline2 = DeviceInventoryRecord.empty(id: "offline-2", source: "test")
        offline2.name = "Offline-2"
        offline2.daysSinceContact = 60
        records.append(offline2)

        // 1 inactive (91-180 days)
        var inactive1 = DeviceInventoryRecord.empty(id: "inactive-1", source: "test")
        inactive1.name = "Inactive-1"
        inactive1.daysSinceContact = 120
        records.append(inactive1)

        // 1 dormant (180+ days)
        var dormant1 = DeviceInventoryRecord.empty(id: "dormant-1", source: "test")
        dormant1.name = "Dormant-1"
        dormant1.daysSinceContact = 250
        records.append(dormant1)

        let snapshot = StaleDeviceService.snapshot(from: records)

        XCTAssertEqual(snapshot.totalDevices, 6)
        XCTAssertEqual(snapshot.tierCounts[.recent], 2, "Should have 2 recent devices")
        XCTAssertEqual(snapshot.tierCounts[.offline], 2, "Should have 2 offline devices")
        XCTAssertEqual(snapshot.tierCounts[.inactive], 1, "Should have 1 inactive device")
        XCTAssertEqual(snapshot.tierCounts[.dormant], 1, "Should have 1 dormant device")

        // Verify devices are sorted within tiers (most-stale first)
        let offlineDevices = snapshot.devicesByTier[.offline] ?? []
        XCTAssertEqual(offlineDevices.count, 2)
        XCTAssertEqual(offlineDevices[0].name, "Offline-2", "Should be sorted by daysSinceContact descending")
        XCTAssertEqual(offlineDevices[1].name, "Offline-1")

        // Verify recent tier includes the nil case
        let recentDevices = snapshot.devicesByTier[.recent] ?? []
        XCTAssertEqual(recentDevices.count, 2)
        XCTAssertTrue(recentDevices.contains { $0.name == "Recent-1" })
        XCTAssertTrue(recentDevices.contains { $0.name == "Recent-2" })
    }

    func testEmptyInputReturnsEmptySnapshot() throws {
        let snapshot = StaleDeviceService.snapshot(from: [])

        XCTAssertEqual(snapshot.totalDevices, 0)
        XCTAssertEqual(snapshot.tierCounts[.recent], 0)
        XCTAssertEqual(snapshot.tierCounts[.offline], 0)
        XCTAssertEqual(snapshot.tierCounts[.inactive], 0)
        XCTAssertEqual(snapshot.tierCounts[.dormant], 0)
        XCTAssertTrue(snapshot.devicesByTier[.recent]?.isEmpty ?? true)
        XCTAssertTrue(snapshot.devicesByTier[.offline]?.isEmpty ?? true)
        XCTAssertTrue(snapshot.devicesByTier[.inactive]?.isEmpty ?? true)
        XCTAssertTrue(snapshot.devicesByTier[.dormant]?.isEmpty ?? true)
        XCTAssertNil(snapshot.sourceFile)
        XCTAssertNil(snapshot.snapshotDate)
    }

    func testSortingWithinTiers() throws {
        // Create multiple devices in the same tier with different daysSinceContact values
        var records: [DeviceInventoryRecord] = []

        var device1 = DeviceInventoryRecord.empty(id: "device-1", source: "test")
        device1.name = "Device-1"
        device1.daysSinceContact = 45  // offline
        records.append(device1)

        var device2 = DeviceInventoryRecord.empty(id: "device-2", source: "test")
        device2.name = "Device-2"
        device2.daysSinceContact = 75  // offline
        records.append(device2)

        var device3 = DeviceInventoryRecord.empty(id: "device-3", source: "test")
        device3.name = "Device-3"
        device3.daysSinceContact = 35  // offline
        records.append(device3)

        let snapshot = StaleDeviceService.snapshot(from: records)

        let offlineDevices = snapshot.devicesByTier[.offline] ?? []
        XCTAssertEqual(offlineDevices.count, 3)

        // Should be sorted descending by daysSinceContact (most-stale first)
        XCTAssertEqual(offlineDevices[0].name, "Device-2") // 75 days
        XCTAssertEqual(offlineDevices[1].name, "Device-1") // 45 days
        XCTAssertEqual(offlineDevices[2].name, "Device-3") // 35 days
    }
}