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

    func testComplianceServerStaleFlagAlwaysWins() {
        // Server-side `stale: true` must OR in regardless of day count / threshold.
        let item: [String: Any] = [
            "days_since_contact": "5",
            "last_contact": "2026-07-08T12:00:00.000Z",
            "managed": true,
            "name": "Freshmac",
            "serial": "C02FRESH01",
            "stale": true,
        ]

        let record = DeviceInventoryService.recordFromCompliance(
            item, source: "device-compliance.json", staleThresholdDays: 365
        )
        XCTAssertEqual(record.daysSinceContact, 5)
        XCTAssertTrue(record.stale, "server stale flag must OR in even below the threshold")
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
}
