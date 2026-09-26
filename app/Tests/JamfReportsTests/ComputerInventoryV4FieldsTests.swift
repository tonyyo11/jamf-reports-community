import Foundation
import XCTest
@testable import JamfReports

/// jamf-cli reads computer inventory from Jamf Pro's v4 API, which renamed v3's
/// `general.lastContactTime` to `lastCheckIn` and `lastReportedIp` to `lastReportedIpV4`.
/// v4's `general.lastContact` is a separate field that is null on most Macs.
final class ComputerInventoryV4FieldsTests: XCTestCase {

    private var report: HtmlReport {
        HtmlReport(config: ReportConfig().withDefaults(),
                   dataDir: URL(fileURLWithPath: "/tmp/nonexistent"))
    }

    /// `computers-v4.json` has the key layout jamf-cli 1.31.1 returns from Jamf Pro 11.32 for
    /// `--section GENERAL --section HARDWARE`, with synthetic values and hardware trimmed.
    private func fixtureItems() throws -> [String: [String: Any]] {
        let url = TestFixtures.dir("jamf-cli-data/computers-v4/computers-v4.json")
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        var byName: [String: [String: Any]] = [:]
        for item in try XCTUnwrap(parsed as? [[String: Any]]) {
            let general = try XCTUnwrap(item["general"] as? [String: Any])
            byName[try XCTUnwrap(general["name"] as? String)] = item
        }
        return byName
    }

    private func fixtureRecords() throws -> [String: DeviceInventoryRecord] {
        try fixtureItems().mapValues {
            DeviceInventoryService.recordFromComputer($0, source: "computers-v4.json")
        }
    }

    private func record(_ general: [String: Any]) -> DeviceInventoryRecord {
        DeviceInventoryService.recordFromComputer(["general": general], source: "computers.json")
    }

    /// Half a day past the whole days, so a daylight-saving change in between
    /// cannot move the count.
    private func stamp(daysAgo: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date().addingTimeInterval(-Double(daysAgo) * 86_400 - 43_200))
    }

    func testV4RecordsTakeTheirLastContactFromLastCheckIn() throws {
        let records = try fixtureRecords()

        let checkedIn = try XCTUnwrap(records["Lab-Mac-21"])
        XCTAssertEqual(checkedIn.lastContact, "2022-04-11T09:15:42.318Z")
        XCTAssertNotNil(checkedIn.daysSinceContact)
        XCTAssertTrue(checkedIn.stale, "a Mac last checked in during 2022 is past the threshold")

        XCTAssertEqual(records["Lab-Mac-22"]?.lastContact, "2024-03-18T13:02:51.447Z",
                       "lastCheckIn, not v4's separate lastContact")

        let neither = try XCTUnwrap(records["Lab-Mac-23"])
        XCTAssertEqual(neither.lastContact, "")
        XCTAssertNil(neither.daysSinceContact)
    }

    func testV4RecordsKeepLastIpAddressAheadOfTheReportedIPv4() throws {
        let records = try fixtureRecords()
        XCTAssertEqual(records["Lab-Mac-21"]?.ipAddress, "203.0.113.21")
        XCTAssertEqual(records["Lab-Mac-22"]?.ipAddress, "203.0.113.22")
    }

    func testV3AndV4NamesGiveTheSameContactAgeAndReportedIP() {
        let lastCheckIn = stamp(daysAgo: 3)
        let v3 = record(["name": "Mac-v3", "lastContactTime": lastCheckIn,
                         "lastReportedIp": "203.0.113.41"])
        let v4 = record(["name": "Mac-v4", "lastCheckIn": lastCheckIn, "lastContact": NSNull(),
                         "lastReportedIpV4": "203.0.113.41"])

        XCTAssertEqual(v3.lastContact, lastCheckIn)
        XCTAssertEqual(v4.lastContact, lastCheckIn)
        XCTAssertEqual(v4.daysSinceContact, 3)
        XCTAssertEqual(v3.daysSinceContact, v4.daysSinceContact)
        XCTAssertEqual(v3.ipAddress, "203.0.113.41")
        XCTAssertEqual(v4.ipAddress, "203.0.113.41")
    }

    func testHTMLLastContactReadsLastCheckInThenV3ThenInventoryDate() throws {
        let items = try fixtureItems()
        let report = report

        XCTAssertEqual(report.inventoryLastContact(try XCTUnwrap(items["Lab-Mac-21"])),
                       "2022-04-11T09:15:42.318Z")
        XCTAssertEqual(report.inventoryLastContact(try XCTUnwrap(items["Lab-Mac-22"])),
                       "2024-03-18T13:02:51.447Z")
        XCTAssertEqual(report.inventoryLastContact(try XCTUnwrap(items["Lab-Mac-23"])),
                       "2025-06-02T08:11:19.034Z", "no check-in on record: last inventory update")
        XCTAssertEqual(report.inventoryLastContact(["general": [
            "lastContactTime": "2024-01-02T03:04:05Z", "reportDate": "2023-12-01T00:00:00Z",
        ]]), "2024-01-02T03:04:05Z")
    }

    func testInterventionListAgesV4MacsByCheckInNotByInventory() {
        let checkedInRecently: [String: Any] = ["general": [
            "name": "Fresh-Mac", "lastCheckIn": stamp(daysAgo: 2), "lastContact": NSNull(),
            "reportDate": stamp(daysAgo: 90),
        ]]
        let silent: [String: Any] = ["general": [
            "name": "Silent-Mac", "lastCheckIn": stamp(daysAgo: 90), "lastContact": NSNull(),
            "reportDate": stamp(daysAgo: 90),
        ]]

        let html = report.buildInterventionList(computersInventory: [checkedInRecently, silent])

        XCTAssertTrue(html.contains("Silent-Mac"))
        XCTAssertFalse(html.contains("Fresh-Mac"), "checked in 2 days ago, so not stale")
    }
}
