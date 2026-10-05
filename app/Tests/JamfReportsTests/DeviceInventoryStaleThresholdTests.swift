import Foundation
import XCTest
@testable import JamfReports

/// Verifies `record.stale` honors the configured `thresholds.stale_device_days`
/// so the Devices/Outreach screens agree with Overview/Fleet at any threshold.
/// Row shapes mirror the live jamf-cli snapshots under
/// `~/Jamf-Reports/<profile>/jamf-cli-data/{device-compliance,computers}/`.
final class DeviceInventoryStaleThresholdTests: XCTestCase {

    // MARK: - device-compliance (days_since_contact is a String; carries a server `stale` bool)

    func testComplianceStaleRespectsThresholdBelowBoundary() {
        // Real device-compliance row shape: String day count, ISO last_contact,
        // server-provided `stale` flag. 40 days, server says not stale.
        let item: [String: Any] = [
            "days_since_contact": "40",
            "last_contact": "2026-06-01T12:00:00.000Z",
            "managed": true,
            "name": "Bisonlead",
            "os_version": "15.5",
            "serial": "C02ABC123",
            "stale": false,
        ]

        let at45 = DeviceInventoryService.recordFromCompliance(
            item, source: "device-compliance.json", staleThresholdDays: 45
        )
        XCTAssertEqual(at45.daysSinceContact, 40)
        XCTAssertFalse(at45.stale, "40 days must not be stale at threshold 45")

        let at30 = DeviceInventoryService.recordFromCompliance(
            item, source: "device-compliance.json", staleThresholdDays: 30
        )
        XCTAssertTrue(at30.stale, "40 days must be stale at threshold 30")
    }

    func testComplianceServerStaleFlagOnlyDecidesARowWithNoDayCount() {
        // jamf-cli's `stale` flag is a 14-day cut. With a day count the threshold decides.
        let dated: [String: Any] = [
            "days_since_contact": "5",
            "managed": true,
            "name": "Freshmac",
            "serial": "C02FRESH01",
            "stale": true,
        ]
        let record = DeviceInventoryService.recordFromCompliance(
            dated, source: "device-compliance.json", staleThresholdDays: 365
        )
        XCTAssertEqual(record.daysSinceContact, 5)
        XCTAssertFalse(record.stale, "5 days is not stale at 365 whatever the 14-day flag says")

        // With no day count at all the flag is the only evidence there is.
        let undated: [String: Any] = ["name": "Nodays", "serial": "C02NODAYS1", "stale": true]
        let fallback = DeviceInventoryService.recordFromCompliance(
            undated, source: "device-compliance.json", staleThresholdDays: 365
        )
        XCTAssertNil(fallback.daysSinceContact)
        XCTAssertTrue(fallback.stale)
    }

    func testComplianceMacAtExactlyTheThresholdIsNotStaleOneDayLaterIs() {
        func record(days: String) -> DeviceInventoryRecord {
            DeviceInventoryService.recordFromCompliance(
                ["days_since_contact": days, "name": "M", "serial": "S", "stale": true],
                source: "dc.json", staleThresholdDays: 30)
        }
        XCTAssertFalse(record(days: "30").stale, "30 days is not more than 30")
        XCTAssertTrue(record(days: "31").stale)
    }

    func testCSVMacAtExactlyTheThresholdIsNotStaleOneDayLaterIs() {
        func record(daysAgo: Int) -> DeviceInventoryRecord {
            let stamp = Date().addingTimeInterval(-Double(daysAgo) * 86_400 - 3_600)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return DeviceInventoryService.recordFromCSV(
                ["Computer Name": "M", "Serial Number": "S",
                 "Last Check-in": formatter.string(from: stamp)],
                source: "fleet.csv", staleThresholdDays: 30)
        }
        XCTAssertEqual(record(daysAgo: 30).daysSinceContact, 30)
        XCTAssertFalse(record(daysAgo: 30).stale)
        XCTAssertTrue(record(daysAgo: 31).stale)
    }

    // MARK: - One rule for a record

    func testRecordIsStaleOnlyPastTheThresholdAndSnapshotCountsTheSameMacs() {
        func record(_ id: String, days: Int?, flag: Bool = false) -> DeviceInventoryRecord {
            var r = DeviceInventoryRecord.empty(id: id, source: "test")
            r.daysSinceContact = days
            r.stale = flag
            return r
        }
        let records = [
            record("29", days: 29), record("30", days: 30), record("31", days: 31),
            record("flag-only", days: nil, flag: true), record("clear", days: nil),
            // A day count wins over a flag set by another source.
            record("stale-flag-fresh-days", days: 5, flag: true),
        ]
        XCTAssertEqual(records.filter { $0.isStale(atDays: 30) }.map(\.id),
                       ["31", "flag-only"])

        let snapshot = DeviceInventorySnapshot(
            devices: records, patchTitles: [], sourceFiles: [], warnings: [],
            generatedAt: "", generatedDate: nil, isDemo: false)
        XCTAssertEqual(snapshot.staleCount(thresholdDays: 30), 2)

        // Offline Outreach: every tier after Recent holds exactly the stale Macs with a count.
        let tiers = StaleDeviceService.snapshot(from: records, staleDays: 30)
        let pastRecent = StaleDeviceService.Tier.allCases.filter { $0 != .recent }
            .reduce(0) { $0 + (tiers.tierCounts[$1] ?? 0) }
        XCTAssertEqual(pastRecent, 1, "only the 31-day Mac; the others are Recent")
    }

    /// The sources merge by ORing their stale flags but keep the smallest day count, so
    /// a Mac an older snapshot saw at 40 days and a newer one at 2 must read as current.
    func testRestatingStaleFollowsTheMergedDayCount() {
        var merged = DeviceInventoryRecord.empty(id: "m", source: "computers + device-compliance")
        merged.daysSinceContact = 2
        merged.stale = true
        XCTAssertFalse(
            DeviceInventoryService.restatingStale(merged, rule: StaleRule(days: 30)).stale)

        merged.daysSinceContact = 30
        XCTAssertFalse(
            DeviceInventoryService.restatingStale(merged, rule: StaleRule(days: 30)).stale)
        merged.daysSinceContact = 31
        merged.stale = false
        XCTAssertTrue(
            DeviceInventoryService.restatingStale(merged, rule: StaleRule(days: 30)).stale)

        var undated = DeviceInventoryRecord.empty(id: "u", source: "device-compliance")
        undated.stale = true
        XCTAssertTrue(
            DeviceInventoryService.restatingStale(undated, rule: StaleRule(days: 30)).stale,
                      "no day count: the sources' flag stands")
    }

    func testComplianceDefaultThresholdIsThirty() {
        let item: [String: Any] = [
            "days_since_contact": "31",
            "name": "Edgecase",
            "serial": "C02EDGE001",
            "stale": false,
        ]
        // Default overload (no threshold) must behave as 30.
        let record = DeviceInventoryService.recordFromCompliance(item, source: "dc.json")
        XCTAssertTrue(record.stale, "31 days is stale under the default 30-day threshold")
    }

    // MARK: - load: sources of different ages merge to one reading

    /// A Mac the older device-compliance snapshot saw 40 days quiet (flag set) and the newer
    /// computers snapshot saw 2 days ago is current on every screen that reads `stale`.
    func testLoadReadsAMacTheNewerSnapshotSawCheckInAsCurrent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-stale-merge-\(UUID().uuidString)", isDirectory: true)
        let data = root.appendingPathComponent("merged/jamf-cli-data", isDirectory: true)
        let computers = data.appendingPathComponent("computers", isDirectory: true)
        let compliance = data.appendingPathComponent("device-compliance", isDirectory: true)
        for dir in [computers, compliance] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        try """
        [{"general": {"id": 1, "name": "Mac-A", "lastContactTime": "2 days"},
          "hardware": {"serialNumber": "AAA1"}}]
        """.write(to: computers.appendingPathComponent("computers_20261004T120000.json"),
                  atomically: true, encoding: .utf8)
        try """
        [{"name": "Mac-A", "serial": "AAA1", "managed": true, "stale": true,
          "days_since_contact": "40"}]
        """.write(to: compliance.appendingPathComponent("device-compliance_20261001T120000.json"),
                  atomically: true, encoding: .utf8)

        let snapshot = DeviceInventoryService.load(profile: "merged", demoMode: false)

        let mac = try XCTUnwrap(snapshot.devices.first)
        XCTAssertEqual(snapshot.devices.count, 1)
        XCTAssertEqual(mac.daysSinceContact, 2)
        XCTAssertFalse(mac.stale, "the merge must not keep the older snapshot's stale flag")
        XCTAssertEqual(snapshot.staleCount(thresholdDays: 30), 0)
    }

    // MARK: - computers (stale derived from lastContact → daysSinceContact)

    func testComputerStaleRespectsThreshold() {
        // computers snapshot has no direct day count; daysSinceContact is derived.
        // "40 days" exercises the pre-formatted "N …" label path deterministically.
        let item: [String: Any] = [
            "general": [
                "id": 42,
                "name": "MERIDIAN-JS-MBP",
                "serialNumber": "C02XK9PHJG5J",
                "lastContactTime": "40 days",
            ],
            "hardware": [
                "serialNumber": "C02XK9PHJG5J",
            ],
        ]

        let at45 = DeviceInventoryService.recordFromComputer(
            item, source: "computers.json", staleThresholdDays: 45
        )
        XCTAssertEqual(at45.daysSinceContact, 40)
        XCTAssertFalse(at45.stale, "40 days must not be stale at threshold 45")

        let at30 = DeviceInventoryService.recordFromComputer(
            item, source: "computers.json", staleThresholdDays: 30
        )
        XCTAssertTrue(at30.stale, "40 days must be stale at threshold 30")

        // Default overload behaves as 30.
        let dflt = DeviceInventoryService.recordFromComputer(item, source: "computers.json")
        XCTAssertTrue(dflt.stale, "default threshold is 30 — 40 days is stale")
    }

    func testComputerAtExactlyTheThresholdIsNotStaleOneDayLaterIs() {
        func record(_ label: String) -> DeviceInventoryRecord {
            DeviceInventoryService.recordFromComputer(
                ["general": ["id": 1, "name": "M", "lastContactTime": label],
                 "hardware": ["serialNumber": "S"]],
                source: "computers.json", staleThresholdDays: 30)
        }
        XCTAssertFalse(record("30 days").stale, "30 days is not more than 30")
        XCTAssertTrue(record("31 days").stale)
    }
}
