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

    // MARK: - Config-driven threshold tests

    /// At the default staleDays == 30 the parameterized boundaries must reduce
    /// EXACTLY to the historical 30 / 90 / 180 split — this is a consistency fix,
    /// not a behavior change for default configs.
    func testTierBoundariesDefaultThresholdByteIdentical() throws {
        XCTAssertEqual(StaleDeviceService.Tier.tier(for: 0, staleDays: 30), .recent)
        XCTAssertEqual(StaleDeviceService.Tier.tier(for: 30, staleDays: 30), .recent)
        XCTAssertEqual(StaleDeviceService.Tier.tier(for: 31, staleDays: 30), .offline)
        XCTAssertEqual(StaleDeviceService.Tier.tier(for: 90, staleDays: 30), .offline)
        XCTAssertEqual(StaleDeviceService.Tier.tier(for: 91, staleDays: 30), .inactive)
        XCTAssertEqual(StaleDeviceService.Tier.tier(for: 180, staleDays: 30), .inactive)
        XCTAssertEqual(StaleDeviceService.Tier.tier(for: 181, staleDays: 30), .dormant)
        XCTAssertEqual(StaleDeviceService.Tier.tier(for: nil, staleDays: 30), .recent)

        // contains() at staleDays 30 == the old hardcoded predicate
        XCTAssertTrue(StaleDeviceService.Tier.recent.contains(30, staleDays: 30))
        XCTAssertFalse(StaleDeviceService.Tier.recent.contains(31, staleDays: 30))
        XCTAssertTrue(StaleDeviceService.Tier.offline.contains(31, staleDays: 30))
        XCTAssertTrue(StaleDeviceService.Tier.offline.contains(90, staleDays: 30))
        XCTAssertFalse(StaleDeviceService.Tier.offline.contains(91, staleDays: 30))
        XCTAssertTrue(StaleDeviceService.Tier.inactive.contains(91, staleDays: 30))
        XCTAssertTrue(StaleDeviceService.Tier.inactive.contains(180, staleDays: 30))
        XCTAssertFalse(StaleDeviceService.Tier.inactive.contains(181, staleDays: 30))
        XCTAssertTrue(StaleDeviceService.Tier.dormant.contains(181, staleDays: 30))
    }

    /// At a non-default threshold the boundaries scale as 1× / 3× / 6× —
    /// staleDays 45 → recent 0-45, offline 46-135, inactive 136-270, dormant 271+.
    func testTierBoundariesScaleAtNonDefaultThreshold() throws {
        XCTAssertEqual(StaleDeviceService.Tier.tier(for: 45, staleDays: 45), .recent)
        XCTAssertEqual(StaleDeviceService.Tier.tier(for: 46, staleDays: 45), .offline)
        XCTAssertEqual(StaleDeviceService.Tier.tier(for: 135, staleDays: 45), .offline)
        XCTAssertEqual(StaleDeviceService.Tier.tier(for: 136, staleDays: 45), .inactive)
        XCTAssertEqual(StaleDeviceService.Tier.tier(for: 270, staleDays: 45), .inactive)
        XCTAssertEqual(StaleDeviceService.Tier.tier(for: 271, staleDays: 45), .dormant)

        XCTAssertTrue(StaleDeviceService.Tier.recent.contains(45, staleDays: 45))
        XCTAssertFalse(StaleDeviceService.Tier.recent.contains(46, staleDays: 45))
        XCTAssertTrue(StaleDeviceService.Tier.offline.contains(46, staleDays: 45))
        XCTAssertTrue(StaleDeviceService.Tier.offline.contains(135, staleDays: 45))
        XCTAssertFalse(StaleDeviceService.Tier.offline.contains(136, staleDays: 45))
        XCTAssertTrue(StaleDeviceService.Tier.inactive.contains(136, staleDays: 45))
        XCTAssertTrue(StaleDeviceService.Tier.inactive.contains(270, staleDays: 45))
        XCTAssertFalse(StaleDeviceService.Tier.dormant.contains(270, staleDays: 45))
        XCTAssertTrue(StaleDeviceService.Tier.dormant.contains(271, staleDays: 45))
    }

    /// The default `contains`/`tier` overloads (staleDays omitted) must behave
    /// identically to explicitly passing 30 — proves nothing broke for the many
    /// existing callers that never pass a threshold.
    func testDefaultOverloadsMatchThirtyExplicit() throws {
        for days in [0, 30, 31, 90, 91, 180, 181, 400] {
            XCTAssertEqual(
                StaleDeviceService.Tier.tier(for: days),
                StaleDeviceService.Tier.tier(for: days, staleDays: 30)
            )
        }
    }

    func testSnapshotBucketsAtNonDefaultThreshold() throws {
        func record(_ id: String, _ days: Int) -> DeviceInventoryRecord {
            var r = DeviceInventoryRecord.empty(id: id, source: "test")
            r.name = id
            r.daysSinceContact = days
            return r
        }
        // At staleDays 45: 40→recent, 100→offline, 200→inactive, 300→dormant.
        let records = [record("r", 40), record("o", 100), record("i", 200), record("d", 300)]
        let snapshot = StaleDeviceService.snapshot(from: records, staleDays: 45)

        XCTAssertEqual(snapshot.totalDevices, 4)
        XCTAssertEqual(snapshot.tierCounts[.recent], 1)
        XCTAssertEqual(snapshot.tierCounts[.offline], 1)
        XCTAssertEqual(snapshot.tierCounts[.inactive], 1)
        XCTAssertEqual(snapshot.tierCounts[.dormant], 1)

        // The 100-day device is "offline" at 45 but "inactive" at 30 — proving
        // the threshold actually re-buckets. (Asserted directly to avoid the
        // aggregate-count ambiguity: at staleDays 30 the 40-day device is also
        // offline, so the offline bucket is not empty.)
        XCTAssertEqual(StaleDeviceService.Tier.tier(for: 100, staleDays: 45), .offline)
        XCTAssertEqual(StaleDeviceService.Tier.tier(for: 100, staleDays: 30), .inactive)

        // At staleDays 30 the set re-buckets: 40→offline, 100→inactive, 200/300→dormant.
        let snapshot30 = StaleDeviceService.snapshot(from: records, staleDays: 30)
        XCTAssertEqual(snapshot30.tierCounts[.recent], 0)
        XCTAssertEqual(snapshot30.tierCounts[.offline], 1, "the 40-day device is offline at 30")
        XCTAssertEqual(snapshot30.tierCounts[.inactive], 1, "the 100-day device is inactive at 30")
        XCTAssertEqual(snapshot30.tierCounts[.dormant], 2)
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

    // MARK: - cacheSource tests

    func testCacheSourceNilDataCollectedDateIsNeverFetched() {
        let snapshot = StaleDeviceService.snapshot(from: [], dataCollectedDate: nil)
        XCTAssertEqual(snapshot.cacheSource, .neverFetchedLive)
    }

    func testCacheSourceFreshWithinWindow() {
        let recent = Date().addingTimeInterval(-3600) // 1 hour ago
        let snapshot = StaleDeviceService.snapshot(from: [], dataCollectedDate: recent)
        XCTAssertEqual(snapshot.cacheSource, .fresh)
    }

    func testCacheSourceStaleOutsideWindow() {
        let old = Date().addingTimeInterval(-37 * 3600) // 37 hours ago — beyond 36h window
        let snapshot = StaleDeviceService.snapshot(from: [], dataCollectedDate: old)
        if case .stale(let at) = snapshot.cacheSource {
            XCTAssertEqual(at.timeIntervalSince1970, old.timeIntervalSince1970, accuracy: 1)
        } else {
            XCTFail("Expected .stale, got \(snapshot.cacheSource)")
        }
    }

    func testCacheSourceUsesDataCollectedDateNotSnapshotDate() {
        // snapshotDate is most-recent device contact — 3 days ago; that should
        // NOT drive the banner. dataCollectedDate is fresh (1 hour ago).
        var record = DeviceInventoryRecord.empty(id: "r", source: "test")
        record.daysSinceContact = 72
        record.lastContact = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(-72 * 3600)
        )
        let freshCollect = Date().addingTimeInterval(-3600)
        let snapshot = StaleDeviceService.snapshot(from: [record], dataCollectedDate: freshCollect)
        // snapshotDate reflects device activity (3 days back), but cacheSource
        // must be .fresh because the *collection* is only 1 hour old.
        XCTAssertEqual(snapshot.cacheSource, .fresh,
            "cacheSource must use dataCollectedDate, not snapshotDate")
    }

    // MARK: - outreachCSV tests

    func testOutreachCSVHeaderColumns() {
        let csv = StaleDeviceService.outreachCSV(.empty)
        let firstLine = csv.split(separator: "\n", omittingEmptySubsequences: false)[0]
        XCTAssertEqual(
            String(firstLine),
            "Device Name,Serial,Username,Email,Last Check-in,Stale Tier"
        )
    }

    func testOutreachCSVEmptySnapshotYieldsHeaderOnly() {
        let csv = StaleDeviceService.outreachCSV(.empty)
        XCTAssertEqual(csv, StaleDeviceService.outreachCSVHeader + "\n")
    }

    func testOutreachCSVContainsAllTiers() {
        var offline = DeviceInventoryRecord.empty(id: "o1", source: "test")
        offline.name = "Offline-Mac"
        offline.serial = "SER001"
        offline.user = "jdoe"
        offline.email = "jdoe@example.com"
        offline.lastContact = "2024-01-01"
        offline.daysSinceContact = 60

        var dormant = DeviceInventoryRecord.empty(id: "d1", source: "test")
        dormant.name = "Dormant-Mac"
        dormant.serial = "SER002"
        dormant.daysSinceContact = 200

        let snapshot = StaleDeviceService.snapshot(from: [offline, dormant])
        let csv = StaleDeviceService.outreachCSV(snapshot)
        XCTAssertTrue(csv.contains("Offline-Mac"), "offline tier device must appear")
        XCTAssertTrue(csv.contains("Dormant-Mac"), "dormant tier device must appear")
        XCTAssertTrue(csv.contains("Offline"), "Offline tier label must appear")
        XCTAssertTrue(csv.contains("Dormant"), "Dormant tier label must appear")
    }

    func testOutreachCSVRowColumnCount() {
        var record = DeviceInventoryRecord.empty(id: "r1", source: "test")
        record.name = "Test-Mac"
        record.serial = "SERIAL01"
        record.user = "alice"
        record.email = "alice@example.com"
        record.lastContact = "2024-03-15"
        record.daysSinceContact = 45 // offline tier

        let csv = StaleDeviceService.outreachCSV(StaleDeviceService.snapshot(from: [record]))
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
        // header + 1 data row
        XCTAssertGreaterThanOrEqual(lines.count, 2)
        let dataLine = String(lines[1])
        // 6 columns → 5 commas (unquoted, no commas in values)
        let commaCount = dataLine.filter { $0 == "," }.count
        XCTAssertEqual(commaCount, 5, "Each data row must have exactly 6 columns")
    }

    func testOutreachCSVNeutralizesFormulaInjection() {
        var record = DeviceInventoryRecord.empty(id: "evil", source: "test")
        record.name = "=HYPERLINK(\"http://evil\",\"x\")"
        record.serial = "+SER001"
        record.user = "@jdoe"
        record.email = "-admin@example.com"
        record.daysSinceContact = 60

        let csv = StaleDeviceService.outreachCSV(StaleDeviceService.snapshot(from: [record]))
        XCTAssertTrue(csv.contains("\t=HYPERLINK"),
                      "Leading '=' must be tab-prefixed")
        XCTAssertTrue(csv.contains("\t+SER001"),
                      "Leading '+' must be tab-prefixed")
        XCTAssertTrue(csv.contains("\t@jdoe"),
                      "Leading '@' must be tab-prefixed")
        XCTAssertTrue(csv.contains("\t-admin"),
                      "Leading '-' must be tab-prefixed")
    }

    func testOutreachCSVQuotesFieldsContainingCommas() {
        var record = DeviceInventoryRecord.empty(id: "comma", source: "test")
        record.name = "Mac, Lab 01"
        record.daysSinceContact = 45

        let csv = StaleDeviceService.outreachCSV(StaleDeviceService.snapshot(from: [record]))
        XCTAssertTrue(csv.contains("\"Mac, Lab 01\""),
                      "A device name with a comma must be RFC 4180 quoted")
    }

    func testOutreachCSVTrailingNewline() {
        let csv = StaleDeviceService.outreachCSV(.empty)
        XCTAssertTrue(csv.hasSuffix("\n"), "CSV output must end with a trailing newline")
    }
}