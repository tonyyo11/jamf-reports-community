import Foundation
import XCTest
@testable import JamfReports

final class SummaryDeviceMapsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let iso = ISO8601DateFormatter()

    private func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    /// The captured `computers-v4` rows; the fixture has no `operatingSystem`, so a test that
    /// needs a version sets it on the record.
    private func fixtureRecords() throws -> [DeviceInventoryRecord] {
        let url = TestFixtures.dir("jamf-cli-data/computers-v4/computers-v4.json")
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(parsed as? [[String: Any]]).map {
            DeviceInventoryService.recordFromComputer($0, source: "computers-v4.json")
        }
    }

    private func mobileItems() throws -> [MobileDeviceInventoryItem] {
        let url = TestFixtures.dir(
            "jamf-cli-data-mobile-sections/mobile-devices-list/"
                + "mobile-devices-list_2026-10-02T120000000000.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([MobileDeviceInventoryItem].self, from: data)
    }

    func testModelFamilies() {
        let cases = [
            ("MacBook Air (M2, 2022)", "MacBook Air"),
            ("MacBook Pro (14-inch, 2023)", "MacBook Pro"),
            ("MacBook (Retina)", "MacBook"), ("Mac mini (M2, 2023)", "Mac mini"),
            ("iMac Pro (2017)", "iMac"), ("Mac Pro (2019)", "Mac Pro"),
            ("Mac Studio (2022)", "Mac Studio"), ("Mac14,13", "Other"), ("", "Other"),
        ]
        for (name, family) in cases { XCTAssertEqual(SummaryDeviceMaps.modelFamily(name), family) }
        XCTAssertEqual(SummaryDeviceMaps.modelFamily(nil), "Other")
    }

    func testOSMajorKey() {
        let key = SummaryDeviceMaps.osMajorKey
        XCTAssertEqual(key("macOS", "26.6.2"), "macOS 26")
        XCTAssertEqual(key("iOS", "7.1.2"), "iOS 7")
        XCTAssertNil(key("macOS", ""))
        XCTAssertNil(key("macOS", nil))
        XCTAssertNil(key("macOS", "beta"))
    }

    func testComputersFromFixture() throws {
        var records = try fixtureRecords()
        records[0].osVersion = "26.1"
        records[1].osVersion = "26.0.1"
        let result = SummaryDeviceMaps.computers(records, rule: StaleRule(days: 30), now: now)
        XCTAssertEqual(result.osMajor, ["macOS 26": 2])
        XCTAssertEqual(result.modelFamily, ["MacBook Air": 1, "MacBook Pro": 1, "Mac mini": 1])
        XCTAssertNotNil(result.lastSeen)
    }

    func testIdentifierOnlyModelIsOther() throws {
        var record = try XCTUnwrap(fixtureRecords().first)
        record.marketingModel = ""
        let result = SummaryDeviceMaps.computers([record], rule: StaleRule(days: 30), now: now)
        XCTAssertEqual(result.modelFamily, ["Other": 1])
    }

    func testComputerBucketEdgesAndNever() throws {
        var template = try XCTUnwrap(fixtureRecords().first)
        template.inventoryDate = nil
        template.contactDate = nil
        template.daysSinceContact = nil
        func record(_ checkIn: Date?) -> DeviceInventoryRecord {
            var copy = template
            copy.checkInDate = checkIn
            return copy
        }
        let records = [
            record(ago(0.5)), record(ago(1)), record(ago(6.9)), record(ago(7)), record(ago(40)),
            record(nil),
        ]
        let counts = SummaryDeviceMaps.computers(records, rule: StaleRule(days: 30), now: now)
            .lastSeen
        XCTAssertEqual(counts?.underOneDay, 1)
        XCTAssertEqual(counts?.underSevenDays, 2)
        XCTAssertEqual(counts?.sevenDaysOrMore, 2)
        XCTAssertEqual(counts?.never, 1)
    }

    func testNoDevicesGivesNilMaps() {
        let result = SummaryDeviceMaps.computers([], rule: StaleRule(days: 30), now: now)
        XCTAssertTrue(result.osMajor.isEmpty)
        XCTAssertNil(result.lastSeen)
        let fields = SummaryDeviceMaps.jamfPro(
            computersData: nil, mobileData: nil, rule: StaleRule(days: 30), now: now)
        XCTAssertEqual(fields, SummaryDeviceMaps.Fields())
        XCTAssertNil(SummaryDeviceMaps.schoolFields([], now: now).lastSeen)
    }

    func testMobileFromFixture() throws {
        let result = SummaryDeviceMaps.mobile(try mobileItems(), now: now)
        XCTAssertEqual(result.formFactor, ["iPhone": 3, "iPad": 3])
        XCTAssertEqual(result.osMajor, ["iOS 7": 2, "iOS 8": 1, "iPadOS 8": 3])
        XCTAssertEqual(result.lastSeen?.sevenDaysOrMore, 6)
        XCTAssertNil(result.lastSeen?.never)
        XCTAssertNil(result.lastSeen?.underOneDay)
    }

    func testMobileOnlyFleetFieldsHaveNoComputerMaps() throws {
        let url = TestFixtures.dir(
            "jamf-cli-data-mobile-sections/mobile-devices-list/"
                + "mobile-devices-list_2026-10-02T120000000000.json")
        let fields = SummaryDeviceMaps.jamfPro(
            computersData: nil, mobileData: try Data(contentsOf: url),
            rule: StaleRule(days: 30), now: now)
        XCTAssertNil(fields.modelFamily)
        XCTAssertNil(fields.lastSeen?.computers)
        XCTAssertEqual(fields.lastSeen?.mobile?.sevenDaysOrMore, 6)
        XCTAssertEqual(fields.formFactor?["iPad"], 3)
    }

    func testSchoolRows() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p9-school-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try SchoolRows.write([
            SchoolRows.device(1, ["os": "macOS 26.6.2", "lastCheckin": iso.string(from: ago(0.2))]),
            SchoolRows.device(2, ["os": "macOS 26.0", "lastCheckin": iso.string(from: ago(9))]),
            SchoolRows.device(3, ["os": "iPadOS 18.1", "lastCheckin": iso.string(from: ago(3))]),
            SchoolRows.device(4, ["os": "iOS", "lastCheckin": iso.string(from: ago(3))]),
        ], kind: "school-devices", into: dir)
        let devices = SchoolFleetService.load(dataDir: dir).devices
        let fields = SummaryDeviceMaps.schoolFields(devices, now: now)
        XCTAssertEqual(fields.osMajor, ["macOS 26": 2, "iPadOS 18": 1])
        XCTAssertEqual(fields.lastSeen?.computers?.underOneDay, 1)
        XCTAssertEqual(fields.lastSeen?.computers?.sevenDaysOrMore, 1)
        XCTAssertEqual(fields.lastSeen?.mobile?.underSevenDays, 2)
        XCTAssertNil(fields.lastSeen?.computers?.never)
    }
}
